// lib/services/algorithms/single_machine.dart
//
// Changes from previous version:
//   • SingleMachineInput gains a [jobState] field ("Estado dejado en la máquina").
//   • SingleMachine accepts an optional [setupHelper] (SetupTimeHelper).
//   • All scheduling rules apply setup time BEFORE the processing window,
//     tracking _lastJobState across consecutive jobs.
//   • _ADAPTADO rules sort by effective processing time (p_j + s_{prev→j}).
//
// ─────────────────────────────────────────────────────────────────────────────
// HOW SETUP TIMES ARE INTEGRATED — SINGLE MACHINE SPECIFICS
// ─────────────────────────────────────────────────────────────────────────────
//
// Single machine is simpler than flexible flow shop because there is exactly
// ONE machine, so:
//
//   1. There is no machine-selection step.  The one machine always processes
//      the next job in sequence.
//
//   2. Setup is applied at the START of each job, between the end of the
//      previous job and the start of the current one:
//
//        setupStart   = max(scheduleTime, job.availableDate)
//        setupEnd     = setupStart + s_{prevJobState → currentJobState}
//        processStart = setupEnd
//        processEnd   = processStart + job.machineDuration
//
//      The machine is occupied from setupStart through processEnd.
//      scheduleTime advances to processEnd after each job.
//
//   3. ADAPTADO variants sort by effective processing time:
//
//        p_eff(i→j) = p_j + s_{prevJobState → j.jobState}
//
//      Because prevJobState changes after each assignment, ADAPTADO rules
//      use a dynamic loop (re-sort before each pick), matching the
//      FlexibleFlowShop pattern exactly.
//
//   4. Non-ADAPTADO rules sort once at the start.  Setup time is still
//      applied during scheduling (in _scheduleJobs), so the Gantt/output
//      times are always correct.  Only the ORDERING ignores setup; the
//      TIMING never does.
//
//   5. When setupHelper is null (no matrix configured) the algorithm behaves
//      exactly as before — zero setup cost, full backward compatibility.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
import 'dart:math';

// =============================================================================
// Input / Output models
// =============================================================================

class SingleMachineInput {
  final int jobId;
  final Duration machineDuration;
  final DateTime dueDate;
  final int priority;
  final DateTime availableDate;

  /// Product family / job type — used as the matrix row/column label.
  /// Maps to "Estado dejado en la maquina" from the job creation form.
  /// Defaults to 'A' so existing call-sites that don't pass a state still work.
  final String jobState;

  SingleMachineInput(
    this.jobId,
    this.machineDuration,
    this.dueDate,
    this.priority,
    this.availableDate, {
    this.jobState = 'A',
  });
}

class SingleMachineOutput {
  final int jobId;
  final Duration processingTime;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime dueDate;
  final Duration delay;

  SingleMachineOutput(
    this.jobId,
    this.processingTime,
    this.startDate,
    this.endDate,
    this.dueDate,
    this.delay,
  );
}

// =============================================================================
// SingleMachine
// =============================================================================

class SingleMachine {
  final int machineId;
  final DateTime startDate;
  final Tuple2<TimeOfDay, TimeOfDay> workingSchedule;
  List<SingleMachineInput> input;
  List<SingleMachineOutput> output = [];

  // ── Setup-time support ────────────────────────────────────────────────────
  // Null means no setup configured → zero changeover cost everywhere.
  final SetupTimeHelper? setupHelper;

  // Tracks the jobState of the last scheduled job so we know the "from" state
  // for the next setup-time lookup.
  String? _lastJobState;

  SingleMachine(
    this.machineId,
    this.startDate,
    this.workingSchedule,
    this.input,
    String rule, {
    this.setupHelper, // <── new optional parameter
  }) {
    switch (rule) {
      case "EDD":            eddRule();               break;
      case "SPT":            sptRule();               break;
      case "LPT":            lptRule();               break;
      case "FIFO":           fifoRule();              break;
      case "WSPT":           wsptRule();              break;
      case "EDD_ADAPTADO":   eddRuleAdapted();        break;
      case "SPT_ADAPTADO":   sptRuleAdapted();        break;
      case "LPT_ADAPTADO":   lptRuleAdapted();        break;
      case "FIFO_ADAPTADO":  fifoRuleAdapted();       break;
      case "WSPT_ADAPTADO":  wsptRuleAdapted();       break;
      case "MINSLACK":       scheduleMinimumSlack();  break;
      case "CR":             scheduleCriticalRatio(); break;
      case "GENETICS":       scheduleGeneticAlgorithm(); break;
    }
  }

  // ===========================================================================
  // Core scheduling primitive — ALL rules funnel through here
  // ===========================================================================

  /// Schedules [sortedJobs] in the given order, applying setup times between
  /// consecutive jobs.
  ///
  /// [startClock] is the initial machine availability time.
  /// [resetLastState] controls whether _lastJobState is reset first (true for
  /// fresh schedules, false when continuing an in-progress schedule like
  /// genetic algorithm reuse).
  void _scheduleJobs(
    List<SingleMachineInput> sortedJobs, {
    DateTime? startClock,
    bool resetLastState = true,
  }) {
    if (resetLastState) _lastJobState = null;

    DateTime clock = startClock ?? _workDayStart(startDate);

    for (final job in sortedJobs) {
      // ── 1. Respect release date (available date) ─────────────────────────
      if (job.availableDate.isAfter(clock)) {
        clock = job.availableDate;
      }

      // ── 2. Snap to working-schedule start if needed ───────────────────────
      clock = _snapToWorkStart(clock);

      // ── 3. Apply sequence-dependent setup time ────────────────────────────
      // s_{prevJobState → job.jobState}.  Zero on cold start (null prev).
      final Duration setup = setupHelper != null
          ? setupHelper!.setupDuration(_lastJobState, job.jobState)
          : Duration.zero;

      // Setup occupies the machine but the job hasn't started yet.
      // We roll the clock forward by setup, then snap again in case setup
      // pushed us past the end of the working day.
      clock = _rollForward(clock, setup);

      // ── 4. Schedule the processing window ─────────────────────────────────
      final DateTime processStart = clock;
      clock = _rollForward(clock, job.machineDuration);
      final DateTime processEnd = clock;

      final Duration delay = processEnd.isAfter(job.dueDate)
          ? processEnd.difference(job.dueDate)
          : Duration.zero;

      output.add(SingleMachineOutput(
        job.jobId,
        job.machineDuration,
        processStart,
        processEnd,
        job.dueDate,
        delay,
      ));

      // ── 5. Remember this job's state for the next setup lookup ────────────
      _lastJobState = job.jobState;
    }
  }

  // ===========================================================================
  // Non-adaptive rules — sort once, then call _scheduleJobs
  // ===========================================================================

  void eddRule() {
    input.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    _scheduleJobs(input);
  }

  void sptRule() {
    input.sort((a, b) => a.machineDuration.compareTo(b.machineDuration));
    _scheduleJobs(input);
  }

  void lptRule() {
    input.sort((a, b) => b.machineDuration.compareTo(a.machineDuration));
    _scheduleJobs(input);
  }

  void fifoRule() {
    input.sort((a, b) => a.availableDate.compareTo(b.availableDate));
    _scheduleJobs(input);
  }

  void wsptRule() {
    input.sort((a, b) => (b.priority / b.machineDuration.inMinutes)
        .compareTo(a.priority / a.machineDuration.inMinutes));
    _scheduleJobs(input);
  }

  // ===========================================================================
  // Adaptive (_ADAPTADO) rules
  // ===========================================================================
  //
  // These rules re-sort the remaining jobs before each pick so that the sort
  // key can reflect the current _lastJobState.  This is the key difference
  // from the non-adaptive variants.
  //
  // For SPT_ADAPTADO, LPT_ADAPTADO, WSPT_ADAPTADO the sort key is the
  // EFFECTIVE processing time p_eff = p_j + s_{prev → j.jobState}.

  void eddRuleAdapted() {
    // EDD_ADAPTADO: due-date order is not affected by setup times, but setup
    // is still applied during scheduling.  We use _dynamicSchedule for
    // consistency (re-sort is cheap and keeps the pattern uniform).
    _dynamicSchedule((remaining) {
      remaining.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    });
  }

  void sptRuleAdapted() {
    // SPT_ADAPTADO: sort by p_eff = p_j + s_{prev → j}
    _dynamicSchedule((remaining) {
      remaining.sort((a, b) =>
          _effectiveMinutes(a).compareTo(_effectiveMinutes(b)));
    });
  }

  void lptRuleAdapted() {
    // LPT_ADAPTADO: longest effective first
    _dynamicSchedule((remaining) {
      remaining.sort((a, b) =>
          _effectiveMinutes(b).compareTo(_effectiveMinutes(a)));
    });
  }

  void fifoRuleAdapted() {
    _dynamicSchedule((remaining) {
      remaining.sort((a, b) => a.availableDate.compareTo(b.availableDate));
    });
  }

  void wsptRuleAdapted() {
    // WSPT_ADAPTADO: priority / p_eff
    _dynamicSchedule((remaining) {
      remaining.sort((a, b) {
        final wa = a.priority / _effectiveMinutes(a);
        final wb = b.priority / _effectiveMinutes(b);
        return wb.compareTo(wa); // higher ratio first
      });
    });
  }

  /// Picks and schedules one job at a time, re-applying [sortFn] before each
  /// pick so the sort key reflects the updated _lastJobState.
  void _dynamicSchedule(void Function(List<SingleMachineInput>) sortFn) {
    final remaining = List<SingleMachineInput>.from(input);
    _lastJobState = null;

    // We need a running clock that survives between calls to _scheduleJobs.
    // Build it once here.
    DateTime clock = _workDayStart(startDate);

    while (remaining.isNotEmpty) {
      sortFn(remaining);
      final job = remaining.removeAt(0);

      // Schedule this single job, continuing from where the clock is.
      // We bypass _scheduleJobs and inline the logic so we can thread the
      // clock through without resetting state.
      if (job.availableDate.isAfter(clock)) clock = job.availableDate;
      clock = _snapToWorkStart(clock);

      final Duration setup = setupHelper != null
          ? setupHelper!.setupDuration(_lastJobState, job.jobState)
          : Duration.zero;
      clock = _rollForward(clock, setup);

      final DateTime processStart = clock;
      clock = _rollForward(clock, job.machineDuration);
      final DateTime processEnd = clock;

      final Duration delay = processEnd.isAfter(job.dueDate)
          ? processEnd.difference(job.dueDate)
          : Duration.zero;

      output.add(SingleMachineOutput(
        job.jobId, job.machineDuration,
        processStart, processEnd, job.dueDate, delay,
      ));

      _lastJobState = job.jobState;
    }
  }

  /// Effective processing time in minutes: p_j + s_{_lastJobState → j.jobState}.
  /// Used by *_ADAPTADO sort comparators.
  double _effectiveMinutes(SingleMachineInput job) {
    final setup = setupHelper != null
        ? setupHelper!.getSetupTime(_lastJobState, job.jobState)
        : 0.0;
    return job.machineDuration.inMinutes + setup;
  }

  // ===========================================================================
  // Dynamic rules: MinSlack, CR — setup applied via _scheduleJobs
  // ===========================================================================

  void scheduleMinimumSlack() {
    // Slack = d_j - r_j - p_j.  Sort once (static approximation).
    input.sort((a, b) => _slack(a).compareTo(_slack(b)));
    _scheduleJobs(input);
  }

  void scheduleCriticalRatio() {
    input.sort((a, b) => _criticalRatio(a).compareTo(_criticalRatio(b)));
    _scheduleJobs(input);
  }

  int _slack(SingleMachineInput job) {
    final remaining =
        job.dueDate.difference(job.availableDate).inMinutes;
    return remaining - job.machineDuration.inMinutes;
  }

  double _criticalRatio(SingleMachineInput job) {
    final remaining =
        job.dueDate.difference(job.availableDate).inMinutes;
    return remaining / job.machineDuration.inMinutes;
  }

  // ===========================================================================
  // Genetic algorithm (setup applied via _scheduleJobs on the best sequence)
  // ===========================================================================

  void scheduleGeneticAlgorithm() {
    const int populationSize = 50;
    const int generations = 100;
    const double mutationRate = 0.1;

    List<List<SingleMachineInput>> population =
        _initializePopulation(populationSize);

    List<SingleMachineInput> bestIndividual = List.from(input);
    Duration bestFitness = const Duration(days: 9999);

    for (int g = 0; g < generations; g++) {
      final evaluated = population.map((ind) {
        return Tuple2(ind, _evaluateFitness(ind));
      }).toList()
        ..sort((a, b) => a.value2.compareTo(b.value2));

      if (evaluated.first.value2 < bestFitness) {
        bestFitness = evaluated.first.value2;
        bestIndividual = evaluated.first.value1;
      }

      population =
          _generateNewPopulation(evaluated, populationSize, mutationRate);
    }

    // Schedule the best sequence found, with setup times.
    input = bestIndividual;
    _scheduleJobs(input);
  }

  List<List<SingleMachineInput>> _initializePopulation(int size) {
    return List.generate(size, (_) {
      final shuffled = List<SingleMachineInput>.from(input);
      shuffled.shuffle();
      return shuffled;
    });
  }

  /// Fitness = total weighted completion time of the sequence, including setup.
  Duration _evaluateFitness(List<SingleMachineInput> seq) {
    DateTime clock = _workDayStart(seq.first.availableDate);
    Duration total = Duration.zero;
    String? prevState;

    for (final job in seq) {
      if (job.availableDate.isAfter(clock)) clock = job.availableDate;
      clock = _snapToWorkStart(clock);

      final Duration setup = setupHelper != null
          ? setupHelper!.setupDuration(prevState, job.jobState)
          : Duration.zero;
      clock = _rollForward(clock, setup);
      clock = _rollForward(clock, job.machineDuration);

      total += clock.difference(startDate);
      prevState = job.jobState;
    }
    return total;
  }

  List<List<SingleMachineInput>> _generateNewPopulation(
    List<Tuple2<List<SingleMachineInput>, Duration>> evaluated,
    int size,
    double mutationRate,
  ) {
    return List.generate(size, (_) {
      final p1 = _selectParent(evaluated);
      final p2 = _selectParent(evaluated);
      var child = _crossover(p1, p2);
      if (Random().nextDouble() < mutationRate) child = _mutate(child);
      return child;
    });
  }

  List<SingleMachineInput> _selectParent(
      List<Tuple2<List<SingleMachineInput>, Duration>> evaluated) {
    const k = 5;
    final selected = List.generate(
        k, (_) => evaluated[Random().nextInt(evaluated.length)]);
    selected.sort((a, b) => a.value2.compareTo(b.value2));
    return selected.first.value1;
  }

  List<SingleMachineInput> _crossover(
      List<SingleMachineInput> p1, List<SingleMachineInput> p2) {
    final point = Random().nextInt(p1.length);
    final taken = p1.sublist(0, point).map((j) => j.jobId).toSet();
    return [
      ...p1.sublist(0, point),
      ...p2.where((j) => !taken.contains(j.jobId)),
    ];
  }

  List<SingleMachineInput> _mutate(List<SingleMachineInput> ind) {
    if (ind.length < 2) return ind;
    final i = Random().nextInt(ind.length);
    final j = Random().nextInt(ind.length);
    final tmp = ind[i];
    ind[i] = ind[j];
    ind[j] = tmp;
    return ind;
  }

  // ===========================================================================
  // Working-schedule helpers
  // ===========================================================================

  DateTime _workDayStart(DateTime ref) => DateTime(
        ref.year, ref.month, ref.day,
        workingSchedule.value1.hour, workingSchedule.value1.minute,
      );

  /// If [dt] is before the working-day start, snap to it.
  /// If [dt] is after the working-day end, move to next day's start.
  DateTime _snapToWorkStart(DateTime dt) {
    final ws = workingSchedule.value1;
    final we = workingSchedule.value2;
    final startMinutes = ws.hour * 60 + ws.minute;
    final endMinutes = we.hour * 60 + we.minute;
    final dtMinutes = dt.hour * 60 + dt.minute;

    if (dtMinutes < startMinutes) {
      return DateTime(dt.year, dt.month, dt.day, ws.hour, ws.minute);
    }
    if (dtMinutes >= endMinutes) {
      final next = dt.add(const Duration(days: 1));
      return DateTime(next.year, next.month, next.day, ws.hour, ws.minute);
    }
    return dt;
  }

  /// Advances [from] by [duration], rolling over midnight / end-of-day.
  DateTime _rollForward(DateTime from, Duration duration) {
    if (duration == Duration.zero) return from;
    final we = workingSchedule.value2;
    final endOfDay = DateTime(
        from.year, from.month, from.day, we.hour, we.minute);
    final tentative = from.add(duration);
    if (!tentative.isAfter(endOfDay)) return tentative;

    // Spills over end of day — continue next morning.
    final overflow = tentative.difference(endOfDay);
    final ws = workingSchedule.value1;
    final nextMorning = DateTime(
        from.year, from.month, from.day + 1, ws.hour, ws.minute);
    return nextMorning.add(overflow);
  }
}