// =============================================================================
// lib/services/algorithms/flexible_flow_shop.dart
//
// Flexible Flow Shop scheduler — extended with sequence-dependent setup times.
//
// ─────────────────────────────────────────────────────────────────────────────
// HOW SETUP TIMES ARE INTEGRATED — DESIGN RATIONALE
// ─────────────────────────────────────────────────────────────────────────────
//
// 1. WHERE SETUP TIMES LIVE
//    Each machine has its own [SetupTimeMatrix].  The caller builds one
//    [SetupTimeHelper] per machine and passes them in as [setupHelpers], a
//    Map<machineId, SetupTimeHelper>.  When no helper is provided for a
//    machine (null), the algorithm behaves exactly as before — zero setup cost.
//
// 2. WHAT "STATE" MEANS FOR A JOB
//    Every [FlexibleFlowInput] now carries a [jobState] string (e.g. "A").
//    This is the "Estado dejado en la maquina" field from the job form.
//    When a machine finishes job of state "A" and the next job is state "C",
//    the matrix lookup s_{A→C} gives the changeover duration in minutes.
//
// 3. WHERE THE SETUP IS APPLIED  (_assignJobToMachines)
//    After determining which machine to use (and when it is free), the
//    algorithm adds setup BEFORE the processing window:
//
//      machineReady = machinesAvailability[machineId]
//      setupStart   = max(jobStart, machineReady)
//      setupEnd     = setupStart + s_{prevState[machineId] → job.jobState}
//      processStart = setupEnd
//      processEnd   = processStart + processingTime
//
//    This is the correct LEKIN model: setup occupies the machine but the job
//    itself is NOT started until setup is finished.
//
// 4. WHY SETUP IS ADDED TO THE MACHINE TIME, NOT THE JOB TIME
//    In LEKIN and the scheduling literature, setup time is a machine resource
//    cost.  The machine is busy during setup even though the job hasn't
//    started yet.  Therefore machinesAvailability[machineId] is advanced by
//    setup + processing (not just processing).
//
// 5. ADAPTADO VARIANTS (EDD_A, SPT_A, LPT_A, FIFO_A, WSPT_A)
//    The "adapted" rules sort by EFFECTIVE processing time:
//
//      p_eff(i→j, machine) = p_j(machine) + s_{prevState[machine] → jobState_j}
//
//    This makes the sort setup-aware: a job with a short nominal processing
//    time but a large changeover cost from the current machine state may rank
//    worse than a slightly longer job that requires little setup.
//
//    For the initial job (prevState = null) the effective time equals nominal
//    time because s_{null → anything} = 0 (cold start assumption).
//
// 6. TOTAL PROCESSING TIME HELPER (_totalProcessingTime)
//    Used by SPT / LPT / WSPT.  These rules are about the total job length,
//    NOT machine-specific setup, so they continue to use nominal times only.
//    The setup adjustment happens per-assignment in _assignJobToMachines.
//
// 7. MAKESPAN CALCULATION (_calculateMakespanFlexible, used by CDS)
//    Setup is also accounted for inside the makespan estimator so that the
//    CDS algorithm picks sequences that truly minimise the setup-inclusive
//    makespan.
//
// 8. MS / CR / ATCS DYNAMIC RULES
//    These rules call _assignJobToMachines which already incorporates setup,
//    so no additional changes are needed in the rule logic itself.
// =============================================================================

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
import 'package:production_planning/shared/types/rnage.dart';
import 'dart:math';

// =============================================================================
// Input / Output models
// =============================================================================

class FlexibleFlowInput {
  final int jobId;
  final DateTime dueDate;
  final int priority;
  final DateTime availableDate;

  /// Product family / job type — used as the matrix row/column label.
  /// Maps to "Estado dejado en la maquina" from the job creation form.
  final String jobState;

  /// List of (stationId, Map<machineId, processingDuration>) tuples.
  final List<Tuple2<int, Map<int, Duration>>> taskSequence;

  FlexibleFlowInput(
    this.jobId,
    this.dueDate,
    this.priority,
    this.availableDate,
    this.taskSequence, {
    this.jobState = 'A', // default: first product family
  });
}

class FlexibleFlowOutput {
  final int jobId;
  final DateTime dueDate;
  final DateTime startDate;
  final DateTime endTime;

  /// map<stationId, Tuple2<machineId, scheduled range>>
  final Map<int, Tuple2<int, Range>> scheduling;

  FlexibleFlowOutput(
    this.jobId,
    this.dueDate,
    this.startDate,
    this.endTime,
    this.scheduling,
  );
}

// =============================================================================
// FlexibleFlowShop
// =============================================================================

class FlexibleFlowShop {
  final DateTime startDate;
  final Tuple2<TimeOfDay, TimeOfDay> workingSchedule;
  List<FlexibleFlowInput> inputJobs;
  Map<int, DateTime> machinesAvailability;
  List<FlexibleFlowOutput> output = [];

  // ── Setup-time additions ─────────────────────────────────────────────────
  // One SetupTimeHelper per machineId.  Null means no setup for that machine.
  final Map<int, SetupTimeHelper> setupHelpers;

  // Tracks the jobState that each machine last processed so we know the
  // "from" state for the next setup-time lookup.
  final Map<int, String?> _lastJobStateOnMachine = {};

  FlexibleFlowShop(
    this.startDate,
    this.workingSchedule,
    this.inputJobs,
    this.machinesAvailability,
    String rule, {
    this.setupHelpers = const {}, // <── new optional parameter
  }) {
    switch (rule) {
      case "EDD":         eddRule();   break;
      case "SPT":         sptRule();   break;
      case "LPT":         lptRule();   break;
      case "FIFO":        fifoRule();  break;
      case "WSPT":        wsptRule();  break;
      case "EDD_ADAPTADO":  eddaRule();  break;
      case "SPT_ADAPTADO":  sptaRule();  break;
      case "LPT_ADAPTADO":  lptaRule();  break;
      case "FIFO_ADAPTADO": fifoaRule(); break;
      case "WSPT_ADAPTADO": wsptaRule(); break;
      case "MS":            msRule();    break;
      case "CR":            crRule();    break;
      case "ATCS":          atcRule();   break;
      case "JOHNSON":       _applyJohnsonRuleFlexible(inputJobs); break;
      case "CDS":           cdsAlgorithm(); break;
    }
  }

  // ===========================================================================
  // Non-adaptive rules (sort once, then schedule in that order)
  // ===========================================================================

  void eddRule()  => _schedule((a, b) => a.dueDate.compareTo(b.dueDate));
  void sptRule()  => _schedule((a, b) =>
      _totalProcessingTime(a).compareTo(_totalProcessingTime(b)));
  void lptRule()  => _schedule((a, b) =>
      _totalProcessingTime(b).compareTo(_totalProcessingTime(a)));
  void fifoRule() => _schedule((a, b) =>
      a.availableDate.compareTo(b.availableDate));
  void wsptRule() => _schedule((a, b) {
        double wa = a.priority / _totalProcessingTime(a);
        double wb = b.priority / _totalProcessingTime(b);
        return wb.compareTo(wa);
      });

  void _schedule(
    int Function(FlexibleFlowInput, FlexibleFlowInput) comparator,
  ) {
    inputJobs.sort(comparator);
    for (final job in inputJobs) {
      _assignJobToMachines(job);
    }
  }

  // ===========================================================================
  // Core assignment — THIS IS WHERE SETUP TIMES ARE APPLIED
  // ===========================================================================

  void _assignJobToMachines(FlexibleFlowInput job) {
    DateTime jobStartTime = job.availableDate;
    DateTime? actualStartTime;
    DateTime? finalEndTime;
    final Map<int, Tuple2<int, Range>> scheduling = {};

    for (final task in job.taskSequence) {
      final int stationId = task.value1;
      final Map<int, Duration> machinesInStation = task.value2;

      // ── 1. Select the best machine (earliest finish including setup) ────────
      final selected = _selectBestMachine(
        stationId,
        machinesInStation,
        job,
        jobStartTime,
      );
      final int machineId = selected.value2;
      final Duration processingTime = machinesInStation[machineId]!;

      // ── 2. Determine when the machine is free ──────────────────────────────
      final DateTime machineReady =
          machinesAvailability[machineId] ?? startDate;

      DateTime setupStart = jobStartTime.isAfter(machineReady)
          ? jobStartTime
          : machineReady;
      setupStart = _adjustForWorkingSchedule(setupStart);

      // ── 3. Apply sequence-dependent setup time ─────────────────────────────
      // Look up s_{prevState → currentJobState} for this specific machine.
      //
      // WHY per-machine: different machines can have different changeover costs
      // for the same job-type transition (e.g. a high-precision lathe takes
      // longer to re-configure than a general-purpose one).
      final helper = setupHelpers[machineId];
      final String? prevState = _lastJobStateOnMachine[machineId];
      final Duration setup = helper != null
          ? helper.setupDuration(prevState, job.jobState)
          : Duration.zero;

      // Setup occupies the machine before processing starts.
      final DateTime processStart =
          _adjustForWorkingSchedule(setupStart.add(setup));

      // ── 4. Schedule the processing window ──────────────────────────────────
      final DateTime endTime = _adjustEndTimeForWorkingSchedule(
          processStart, processStart.add(processingTime));

      actualStartTime ??= setupStart;
      finalEndTime = endTime;

      scheduling[stationId] = Tuple2(machineId, Range(processStart, endTime));

      // ── 5. Advance machine clock and record the last job state ─────────────
      // The machine is busy from setupStart all the way to endTime.
      machinesAvailability[machineId] = endTime;
      _lastJobStateOnMachine[machineId] = job.jobState; // remember for next job

      jobStartTime = endTime; // next station can start at earliest when this ends
    }

    output.add(FlexibleFlowOutput(
      job.jobId,
      job.dueDate,
      actualStartTime!,
      finalEndTime!,
      scheduling,
    ));
  }

  // ===========================================================================
  // Machine selection — uses setup-inclusive finish time as the tiebreaker
  // ===========================================================================

  /// Returns (stationId, machineId) for the machine that can finish earliest,
  /// accounting for the setup changeover before processing starts.
  ///
  /// WHY include setup here: if two machines are both free at the same time,
  /// we should prefer the one with a lower changeover cost for this job — it
  /// will finish sooner and keep the overall makespan lower.
  Tuple2<int, int> _selectBestMachine(
    int stationId,
    Map<int, Duration> machinesInStation,
    FlexibleFlowInput job,
    DateTime jobEarliestStart,
  ) {
    MapEntry<int, Duration>? best;
    DateTime? bestFinish;

    for (final entry in machinesInStation.entries) {
      final int machineId = entry.key;
      final Duration processing = entry.value;

      final DateTime machineReady =
          machinesAvailability[machineId] ?? startDate;
      DateTime start = jobEarliestStart.isAfter(machineReady)
          ? jobEarliestStart
          : machineReady;
      start = _adjustForWorkingSchedule(start);

      // Include setup when computing candidate finish time.
      final helper = setupHelpers[machineId];
      final Duration setup = helper != null
          ? helper.setupDuration(_lastJobStateOnMachine[machineId], job.jobState)
          : Duration.zero;

      final DateTime finish = _adjustEndTimeForWorkingSchedule(
          start, start.add(setup).add(processing));

      if (bestFinish == null || finish.isBefore(bestFinish!)) {
        bestFinish = finish;
        best = entry;
      }
    }

    return Tuple2(stationId, best!.key);
  }

  // ===========================================================================
  // Nominal processing time helper (unchanged — no setup, just nominal p_j)
  // ===========================================================================

  /// Average nominal processing time across all stations for a job.
  /// Used by SPT, LPT, WSPT, MS, CR, ATCS to rank jobs globally.
  /// Setup is NOT included here because these rules compare job lengths,
  /// not machine-specific changeover costs.
  int _totalProcessingTime(FlexibleFlowInput job) {
    int total = 0;
    for (final task in job.taskSequence) {
      final int avg = task.value2.values
              .fold(Duration.zero, (s, t) => s + t)
              .inMinutes ~/
          task.value2.length;
      total += avg;
    }
    return total;
  }

  // ===========================================================================
  // Adapted (ADAPTADO) rules — sort by setup-inclusive effective processing time
  // ===========================================================================

  // The *_ADAPTADO variants re-sort considering s_{prevState → jobState}
  // before each job assignment.  Because the "previous state" on each machine
  // changes as jobs are assigned, these rules use a dynamic scheduling loop
  // that re-evaluates the sort key after every assignment (_dynamicSchedule).

  void eddaRule()  => _dynamicSchedule((a, b) => a.dueDate.compareTo(b.dueDate));
  void sptaRule()  => _dynamicSchedule((a, b) =>
      _effectiveTotalTime(a).compareTo(_effectiveTotalTime(b)));
  void lptaRule()  => _dynamicSchedule((a, b) =>
      _effectiveTotalTime(b).compareTo(_effectiveTotalTime(a)));
  void fifoaRule() => _dynamicSchedule(
      (a, b) => a.availableDate.compareTo(b.availableDate));
  void wsptaRule() => _dynamicSchedule((a, b) {
        double wa = a.priority / _effectiveTotalTime(a);
        double wb = b.priority / _effectiveTotalTime(b);
        return wb.compareTo(wa);
      });

  /// Effective total processing time: sum of (p_j + s_{prev→j}) across all
  /// stations, using the CURRENT last-state of each machine.
  ///
  /// This is the key difference from the non-ADAPTADO variants: the sort order
  /// can change mid-schedule as setups accumulate, which is exactly the
  /// "adapted" behaviour described in the scheduling literature.
  double _effectiveTotalTime(FlexibleFlowInput job) {
    double total = 0.0;
    for (final task in job.taskSequence) {
      for (final entry in task.value2.entries) {
        final int machineId = entry.key;
        final double nominal = entry.value.inMinutes.toDouble();
        final helper = setupHelpers[machineId];
        final double setup = helper != null
            ? helper.getSetupTime(_lastJobStateOnMachine[machineId], job.jobState)
            : 0.0;
        total += nominal + setup;
      }
    }
    return total / (job.taskSequence.fold(0, (s, t) => s + t.value2.length));
  }

  void _dynamicSchedule(
    int Function(FlexibleFlowInput, FlexibleFlowInput) comparator,
  ) {
    final remaining = List<FlexibleFlowInput>.from(inputJobs);
    while (remaining.isNotEmpty) {
      // Re-sort every iteration so that setup-inclusive keys reflect the
      // current machine states.
      remaining.sort(comparator);
      _assignJobToMachines(remaining.removeAt(0));
    }
  }

  // ===========================================================================
  // Dynamic rules: MS, CR, ATCS (unchanged structure, setup via _assignJobToMachines)
  // ===========================================================================

  void msRule() {
    int accumulated = 0;
    DateTime currentTime = startDate;
    final remaining = List<FlexibleFlowInput>.from(inputJobs);
    while (remaining.isNotEmpty) {
      remaining.sort((a, b) => _calculateSlack(a, accumulated, currentTime)
          .compareTo(_calculateSlack(b, accumulated, currentTime)));
      final job = remaining.removeAt(0);
      _assignJobToMachines(job);
      accumulated += _totalProcessingTime(job);
      currentTime = output.last.endTime;
    }
  }

  void crRule() {
    int accumulated = 0;
    DateTime currentTime = startDate;
    final remaining = List<FlexibleFlowInput>.from(inputJobs);
    while (remaining.isNotEmpty) {
      remaining.sort((a, b) =>
          _calculateCR(a, accumulated, currentTime)
              .compareTo(_calculateCR(b, accumulated, currentTime)));
      final job = remaining.removeAt(0);
      _assignJobToMachines(job);
      accumulated += _totalProcessingTime(job);
      currentTime = output.last.endTime;
    }
  }

  void atcRule() {
    DateTime currentTime = startDate;
    final remaining = List<FlexibleFlowInput>.from(inputJobs);
    output.clear();
    int elapsed = 0;
    const double K = 3.0;
    while (remaining.isNotEmpty) {
      remaining.sort((a, b) =>
          _calculateATCPriority(b, currentTime, elapsed, K)
              .compareTo(_calculateATCPriority(a, currentTime, elapsed, K)));
      final job = remaining.removeAt(0);
      _assignJobToMachines(job);
      elapsed += _totalProcessingTime(job);
      currentTime = output.last.endTime;
    }
  }

  // ===========================================================================
  // Johnson / CDS (unchanged structure; setup applied inside _assignJobToMachines)
  // ===========================================================================

  void _applyJohnsonRuleFlexible(List<FlexibleFlowInput> jobs) {
    final groupI = <FlexibleFlowInput>[];
    final groupII = <FlexibleFlowInput>[];
    for (final job in jobs) {
      final a = job.taskSequence[0].value2.values.first;
      final b = job.taskSequence[1].value2.values.first;
      if (a <= b) { groupI.add(job); } else { groupII.add(job); }
    }
    groupI.sort((a, b) => a.taskSequence[0].value2.values.first
        .compareTo(b.taskSequence[0].value2.values.first));
    groupII.sort((a, b) => b.taskSequence[1].value2.values.first
        .compareTo(a.taskSequence[1].value2.values.first));
    inputJobs = [...groupI, ...groupII];
    _schedule((a, b) => 0);
  }

  void cdsAlgorithm() {
    if (inputJobs.isEmpty) return;
    final int numStations = inputJobs.first.taskSequence.length;
    if (numStations == 2) { _applyJohnsonRuleFlexible(inputJobs); return; }

    List<FlexibleFlowInput> bestSequence = [];
    int bestMakespan = double.maxFinite.toInt();

    for (int k = 1; k < numStations; k++) {
      final tempJobs = inputJobs.map((job) {
        Duration sumA = Duration.zero;
        Duration sumB = Duration.zero;
        for (int i = 0; i < k; i++) {
          sumA += _averageProcessingTime(job.taskSequence[i].value2);
        }
        for (int i = k; i < numStations; i++) {
          sumB += _averageProcessingTime(job.taskSequence[i].value2);
        }
        return FlexibleFlowInput(
          job.jobId, job.dueDate, job.priority, job.availableDate,
          [Tuple2(0, {0: sumA}), Tuple2(1, {1: sumB})],
          jobState: job.jobState,
        );
      }).toList();

      final ordered = _getJohnsonOrderedJobsFlexible(tempJobs);
      final orderedOriginal = ordered.map((e) =>
          inputJobs.firstWhere((j) => j.jobId == e.jobId)).toList();
      final makespan = _calculateMakespanFlexible(orderedOriginal);

      if (makespan < bestMakespan) {
        bestMakespan = makespan;
        bestSequence = orderedOriginal;
      }
    }

    inputJobs = bestSequence;
    _schedule((a, b) => 0);
  }

  // ===========================================================================
  // Working-schedule helpers (unchanged)
  // ===========================================================================

  DateTime _adjustForWorkingSchedule(DateTime start) {
    final ws = workingSchedule.value1;
    final we = workingSchedule.value2;
    if (start.hour < ws.hour ||
        (start.hour == ws.hour && start.minute < ws.minute)) {
      return DateTime(start.year, start.month, start.day, ws.hour, ws.minute);
    } else if (start.hour > we.hour ||
        (start.hour == we.hour && start.minute > we.minute)) {
      return DateTime(
          start.year, start.month, start.day + 1, ws.hour, ws.minute);
    }
    return start;
  }

  DateTime _adjustEndTimeForWorkingSchedule(DateTime start, DateTime end) {
    final we = workingSchedule.value2;
    final endOfDay =
        DateTime(start.year, start.month, start.day, we.hour, we.minute);
    if (end.isAfter(endOfDay)) {
      final remaining = end.difference(endOfDay);
      return DateTime(
        start.year, start.month, start.day + 1,
        workingSchedule.value1.hour, workingSchedule.value1.minute,
      ).add(remaining);
    }
    return end;
  }

  // ===========================================================================
  // CDS / Johnson internal helpers (unchanged except jobState forwarding)
  // ===========================================================================

  Duration _averageProcessingTime(Map<int, Duration> times) {
    if (times.isEmpty) return Duration.zero;
    final totalMs = times.values.fold(0, (s, d) => s + d.inMilliseconds);
    return Duration(milliseconds: totalMs ~/ times.length);
  }

  List<FlexibleFlowInput> _getJohnsonOrderedJobsFlexible(
      List<FlexibleFlowInput> jobs) {
    final groupI = <FlexibleFlowInput>[];
    final groupII = <FlexibleFlowInput>[];
    for (final job in jobs) {
      final a = job.taskSequence[0].value2[0]!;
      final b = job.taskSequence[1].value2[1]!;
      if (a <= b) { groupI.add(job); } else { groupII.add(job); }
    }
    groupI.sort((a, b) =>
        a.taskSequence[0].value2[0]!.compareTo(b.taskSequence[0].value2[0]!));
    groupII.sort((a, b) =>
        b.taskSequence[1].value2[1]!.compareTo(a.taskSequence[1].value2[1]!));
    return [...groupI, ...groupII];
  }

  /// Makespan estimator used by CDS — now accounts for setup times so that
  /// CDS picks sequences that minimise the setup-INCLUSIVE makespan.
  int _calculateMakespanFlexible(List<FlexibleFlowInput> jobSequence) {
    final Map<int, Map<int, DateTime>> stationAvail = {};
    final Map<int, String?> lastState = {};

    for (final job in jobSequence) {
      for (final task in job.taskSequence) {
        stationAvail.putIfAbsent(task.value1, () => {});
        for (final mId in task.value2.keys) {
          stationAvail[task.value1]![mId] = startDate;
        }
      }
    }

    DateTime makespanEnd = startDate;

    for (final job in jobSequence) {
      DateTime jobStart = job.availableDate;

      for (final task in job.taskSequence) {
        final int stationId = task.value1;
        final Map<int, Duration> opts = task.value2;

        int bestMachine = -1;
        DateTime bestFinish = DateTime(9999);

        for (final entry in opts.entries) {
          final int mId = entry.key;
          final Duration dur = entry.value;
          final DateTime mReady = stationAvail[stationId]?[mId] ?? startDate;
          DateTime s = jobStart.isAfter(mReady) ? jobStart : mReady;
          s = _adjustForWorkingSchedule(s);

          // Include setup in the makespan estimate.
          final helper = setupHelpers[mId];
          final Duration setup = helper != null
              ? helper.setupDuration(lastState[mId], job.jobState)
              : Duration.zero;

          final DateTime finish = _adjustEndTimeForWorkingSchedule(
              s, s.add(setup).add(dur));

          if (finish.isBefore(bestFinish)) {
            bestFinish = finish;
            bestMachine = mId;
          }
        }

        final DateTime mReady =
            stationAvail[stationId]![bestMachine]!;
        DateTime s = jobStart.isAfter(mReady) ? jobStart : mReady;
        s = _adjustForWorkingSchedule(s);
        final helper = setupHelpers[bestMachine];
        final Duration setup = helper != null
            ? helper.setupDuration(lastState[bestMachine], job.jobState)
            : Duration.zero;
        final DateTime end = _adjustEndTimeForWorkingSchedule(
            s, s.add(setup).add(opts[bestMachine]!));

        stationAvail[stationId]![bestMachine] = end;
        lastState[bestMachine] = job.jobState; // track for next iteration
        jobStart = end;
        if (end.isAfter(makespanEnd)) makespanEnd = end;
      }
    }

    return makespanEnd.difference(startDate).inMinutes;
  }

  // ===========================================================================
  // MS / CR / ATCS helpers (unchanged)
  // ===========================================================================

  double _calculateCR(
      FlexibleFlowInput job, int accumulated, DateTime current) {
    final remaining = job.dueDate.difference(current).inMinutes - accumulated;
    final p = _totalProcessingTime(job);
    return p > 0 ? (remaining > 0 ? remaining / p : double.infinity) : double.infinity;
  }

  int _calculateSlack(
      FlexibleFlowInput job, int accumulated, DateTime current) {
    final slack = job.dueDate.difference(current).inMinutes -
        _totalProcessingTime(job) - accumulated;
    return slack < 0 ? 0 : slack;
  }

  double _calculateATCPriority(
    FlexibleFlowInput job,
    DateTime current,
    int elapsed,
    double K,
  ) {
    final p = _totalProcessingTime(job);
    final avg = p / job.taskSequence.length;
    final diff = job.dueDate.difference(current).inMinutes.toDouble();
    return (job.priority / p) *
        exp(-max(diff - p - elapsed, 0) / (K * avg));
  }
}