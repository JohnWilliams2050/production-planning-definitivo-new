import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
import 'package:production_planning/shared/types/rnage.dart';
import 'dart:math';

class FlowShopInput {
  final int jobId;
  final int sequenceId;
  final DateTime dueDate;
  final int priority;
  final DateTime availableDate;
  // this list has the order of the tasks, it has a tuple of 2 <task id, machine id>
  final List<Tuple2<int, int>> taskSequence;
  // in this map we have the durations, the id is the task id, and the duration is how long it takes
  final Map<int, Duration> taskTimesInMachines;

  /// Product family / job type — used as the matrix row/column label.
  /// Maps to "Estado dejado en la maquina" from the job creation form.
  final String jobState;

  FlowShopInput(
    this.jobId,
    this.sequenceId,
    this.dueDate,
    this.priority,
    this.availableDate,
    this.taskSequence,
    this.taskTimesInMachines, {
    this.jobState = 'A', // default: first product family
  });
}

class FlowShopOutput {
  final int jobId;
  final DateTime startDate;
  final DateTime dueDate;
  final DateTime endTime;
  // the output, the map has the key the machine id, the value is a tuple of <task id, range start to end time>
  final Map<int, Tuple2<int, Range>> machinesScheduling;

  FlowShopOutput(
    this.jobId,
    this.startDate,
    this.dueDate,
    this.endTime,
    this.machinesScheduling,
  );
}

class FlowShop {
  final DateTime startDate;
  final Tuple2<TimeOfDay, TimeOfDay> workingSchedule; // like 8-17

  List<FlowShopInput> inputJobs = [];
  Map<int, DateTime> machinesAvailability = {};
  List<FlowShopOutput> output = [];

  // ── Setup-time additions ─────────────────────────────────────────────────
  // One SetupTimeHelper per machineId.  Null means no setup for that machine.
  final Map<int, SetupTimeHelper> setupHelpers;

  // Tracks the jobState that each machine last processed so we know the
  // "from" state for the next setup-time lookup.
  final Map<int, String?> _lastJobStateOnMachine = {};

  FlowShop(
    this.startDate,
    this.workingSchedule,
    this.inputJobs,
    this.machinesAvailability,
    String rule, {
    Map<int, SetupTimeHelper>? setupHelpers, // <── new optional parameter
  }) : setupHelpers = setupHelpers ?? {} {
    _initializeMachineLastSequence();
    switch (rule) {
      case "EDD":
        eddRule();
        break;
      case "SPT":
        sptRule();
        break;
      case "LPT":
        lptRule();
        break;
      case "FIFO":
        fifoRule();
        break;
      case "WSPT":
        wsptRule();
        break;
      case "EDD_ADAPTADO":
        eddaRule();
        break;
      case "SPT_ADAPTADO":
        sptaRule();
        break;
      case "LPT_ADAPTADO":
        lptaRule();
        break;
      case "FIFO_ADAPTADO":
        fifoaRule();
        break;
      case "WSPT_ADAPTADO":
        wsptaRule();
        break;
      case "JOHNSON":
        _applyJohnsonRule(inputJobs);
        break;
      case "CDS":
        cdsAlgorithm();
        break;
      case "MINSLACK":
        msRule();
        break;
      case "CR":
        crRule();
        break;
      case "ATCS":
        atcRule();
        break;
      case "GENETICS":
        scheduleGeneticAlgorithm();
        break;
      default:
        // no-op: unknown rule
        break;
    }
  }

  void _initializeMachineLastSequence() {
    for (final job in inputJobs) {
      for (final task in job.taskSequence) {
        _lastJobStateOnMachine.putIfAbsent(task.value2, () => null);
      }
    }
    for (final machineId in machinesAvailability.keys) {
      _lastJobStateOnMachine.putIfAbsent(machineId, () => null);
    }
    for (final machineId in setupHelpers.keys) {
      _lastJobStateOnMachine.putIfAbsent(machineId, () => null);
    }
  }

  /* ---------- Rules (dispatching / sequencing) ---------- */

  void eddRule() => _schedule((a, b) => a.dueDate.compareTo(b.dueDate));
  void sptRule() => _schedule(
        (a, b) => _totalProcessingTime(a).compareTo(_totalProcessingTime(b)),
      );
  void lptRule() => _schedule(
        (a, b) => _totalProcessingTime(b).compareTo(_totalProcessingTime(a)),
      );
  void fifoRule() => _schedule((a, b) => a.availableDate.compareTo(b.availableDate));
  void wsptRule() => _schedule((a, b) {
        double wsptA = a.priority / max(1, _totalProcessingTime(a));
        double wsptB = b.priority / max(1, _totalProcessingTime(b));
        return wsptB.compareTo(wsptA);
      });

  void eddaRule() => _dynamicSchedule((a, b) => a.dueDate.compareTo(b.dueDate));
  void sptaRule() => _dynamicSchedule(
        (a, b) => _effectiveTotalTime(a).compareTo(_effectiveTotalTime(b)),
      );
  void lptaRule() => _dynamicSchedule(
        (a, b) => _effectiveTotalTime(b).compareTo(_effectiveTotalTime(a)),
      );
  void fifoaRule() => _dynamicSchedule((a, b) => a.availableDate.compareTo(b.availableDate));
  void wsptaRule() => _dynamicSchedule((a, b) {
        double wsptA = a.priority / max(1, _effectiveTotalTime(a));
        double wsptB = b.priority / max(1, _effectiveTotalTime(b));
        return wsptB.compareTo(wsptA);
      });

  void msRule() {
    int totalProcessingTimeAccumulated = 0;
    List<FlowShopInput> remainingJobs = List.from(inputJobs);

    while (remainingJobs.isNotEmpty) {
      remainingJobs.sort((a, b) {
        int slackA = _calculateSlack(a, totalProcessingTimeAccumulated);
        int slackB = _calculateSlack(b, totalProcessingTimeAccumulated);
        return slackA.compareTo(slackB);
      });

      FlowShopInput selectedJob = remainingJobs.first;
      _assignJobToMachines(selectedJob);
      totalProcessingTimeAccumulated += _totalProcessingTime(selectedJob);
      remainingJobs.remove(selectedJob);
    }
  }

  void crRule() {
    int totalProcessingTimeAccumulated = 0;
    List<FlowShopInput> remainingJobs = List.from(inputJobs);

    while (remainingJobs.isNotEmpty) {
      remainingJobs.sort((a, b) {
        double crA = _calculateCR(a, totalProcessingTimeAccumulated);
        double crB = _calculateCR(b, totalProcessingTimeAccumulated);
        return crA.compareTo(crB);
      });

      FlowShopInput selectedJob = remainingJobs.first;
      _assignJobToMachines(selectedJob);
      totalProcessingTimeAccumulated += _totalProcessingTime(selectedJob);
      remainingJobs.remove(selectedJob);
    }
  }

  void atcRule() {
    DateTime currentTime = startDate;
    List<FlowShopInput> remainingJobs = List.from(inputJobs);
    output.clear();
    int elapsedTime = 0;
    double K = 3.0;

    while (remainingJobs.isNotEmpty) {
      remainingJobs.sort(
        (a, b) => _calculateATCPriority(
          b,
          currentTime,
          elapsedTime,
          K,
        ).compareTo(_calculateATCPriority(a, currentTime, elapsedTime, K)),
      );
      FlowShopInput selectedJob = remainingJobs.removeAt(0);
      _assignJobToMachines(selectedJob);
      elapsedTime += _totalProcessingTime(selectedJob);
      currentTime = output.last.endTime;
    }
  }

  double _calculateATCPriority(
    FlowShopInput job,
    DateTime currentTime,
    int elapsedTime,
    double k,
  ) {
    int processingTime = _totalProcessingTime(job);
    double avgProcessingTime = max(1, processingTime) / job.taskSequence.length;
    double timeDiff = job.dueDate.difference(currentTime).inMinutes.toDouble();
    double slackTime = (timeDiff - processingTime - elapsedTime).clamp(0, double.infinity);
    double expFactor = exp(-slackTime / (k * avgProcessingTime));
    return (job.priority / max(1, processingTime)) * expFactor;
  }

  void _schedule(int Function(FlowShopInput, FlowShopInput) comparator) {
    inputJobs.sort(comparator);
    for (var job in inputJobs) {
      _assignJobToMachines(job);
    }
  }

  void _dynamicSchedule(int Function(FlowShopInput, FlowShopInput) comparator) {
    List<FlowShopInput> remainingJobs = List.from(inputJobs);
    while (remainingJobs.isNotEmpty) {
      remainingJobs.sort(comparator);
      FlowShopInput selectedJob = remainingJobs.removeAt(0);
      _assignJobToMachines(selectedJob);
    }
  }

  /* ---------- Core scheduling (assignment) ---------- */

  void _assignJobToMachines(FlowShopInput job) {
    DateTime jobStartTime = job.availableDate;
    Map<int, Tuple2<int, Range>> scheduling = {};

    for (var task in job.taskSequence) {
      int taskId = task.value1;
      int machineId = task.value2;
      Duration duration = job.taskTimesInMachines[taskId]!;

      DateTime machineAvailable = machinesAvailability[machineId] ?? startDate;
      DateTime startTime = jobStartTime.isAfter(machineAvailable) ? jobStartTime : machineAvailable;
      startTime = _adjustForWorkingSchedule(startTime);

      // ── Apply sequence-dependent setup time ─────────────────────────────
      // Look up s_{prevState → currentJobState} for this specific machine.
      final helper = setupHelpers[machineId];
      final String? prevState = _lastJobStateOnMachine[machineId];
      final Duration setupDuration = helper != null
          ? helper.setupDuration(prevState, job.jobState)
          : Duration.zero;

      // Setup occupies the machine before processing starts.
      final DateTime processStart =
          _adjustForWorkingSchedule(startTime.add(setupDuration));

      DateTime endTime = _calculateEndWithSchedule(processStart, duration);

      scheduling[machineId] = Tuple2(taskId, Range(processStart, endTime));
      machinesAvailability[machineId] = endTime;
      _lastJobStateOnMachine[machineId] = job.jobState; // remember for next job
      jobStartTime = endTime;
    }

    output.add(
      FlowShopOutput(
        job.jobId,
        job.availableDate,
        job.dueDate,
        jobStartTime,
        scheduling,
      ),
    );
  }

  int _totalProcessingTime(FlowShopInput job) {
    return job.taskTimesInMachines.values.fold(0, (sum, duration) => sum + duration.inMinutes);
  }

  /// Effective total processing time: sum of (p_j + s_{prev→j}) across all
  /// machines, using the CURRENT last-state of each machine.
  ///
  /// This is the key difference from the non-ADAPTADO variants: the sort order
  /// can change mid-schedule as setups accumulate, which is exactly the
  /// "adapted" behaviour described in the scheduling literature.
  double _effectiveTotalTime(FlowShopInput job) {
    double total = 0.0;
    for (final task in job.taskSequence) {
      final int machineId = task.value2;
      final double nominal = job.taskTimesInMachines[task.value1]!.inMinutes.toDouble();
      final helper = setupHelpers[machineId];
      final double setup = helper != null
          ? helper.getSetupTime(_lastJobStateOnMachine[machineId], job.jobState)
          : 0.0;
      total += nominal + setup;
    }
    return total;
  }

  DateTime _adjustForWorkingSchedule(DateTime start) {
    TimeOfDay workingStart = workingSchedule.value1;
    TimeOfDay workingEnd = workingSchedule.value2;

    if (start.hour < workingStart.hour || (start.hour == workingStart.hour && start.minute < workingStart.minute)) {
      return DateTime(start.year, start.month, start.day, workingStart.hour, workingStart.minute);
    } else if (start.hour > workingEnd.hour || (start.hour == workingEnd.hour && start.minute > workingEnd.minute)) {
      return DateTime(start.year, start.month, start.day + 1, workingStart.hour, workingStart.minute);
    }
    return start;
  }

  DateTime _calculateEndWithSchedule(DateTime start, Duration duration) {
    if (duration <= Duration.zero) return start;

    final TimeOfDay workingStart = workingSchedule.value1;
    final TimeOfDay workingEnd = workingSchedule.value2;

    DateTime current = start;
    Duration remaining = duration;

    while (remaining > Duration.zero) {
      final DateTime dayStart = DateTime(current.year, current.month, current.day, workingStart.hour, workingStart.minute);
      final DateTime dayEnd = DateTime(current.year, current.month, current.day, workingEnd.hour, workingEnd.minute);

      if (current.isBefore(dayStart)) {
        current = dayStart;
        continue;
      }

      if (!current.isBefore(dayEnd)) {
        current = DateTime(current.year, current.month, current.day + 1, workingStart.hour, workingStart.minute);
        continue;
      }

      final Duration availableToday = dayEnd.difference(current);
      if (remaining <= availableToday) {
        return current.add(remaining);
      } else {
        remaining -= availableToday;
        current = DateTime(current.year, current.month, current.day + 1, workingStart.hour, workingStart.minute);
      }
    }

    return current;
  }

  int _calculateSlack(FlowShopInput job, int accumulatedTime) {
    int totalProcessingTime = _totalProcessingTime(job);
    DateTime currentTime = DateTime.now();
    int slack = job.dueDate.difference(currentTime).inMinutes - totalProcessingTime - accumulatedTime;
    return slack < 0 ? 0 : slack;
  }

  double _calculateCR(FlowShopInput job, int accumulatedTime) {
    int remainingTime = max(job.dueDate.difference(DateTime.now()).inMinutes - accumulatedTime, 0);
    int processingTime = _totalProcessingTime(job);
    return processingTime > 0 ? remainingTime / processingTime : double.infinity;
  }

  /* ---------- CDS & Johnson helpers ---------- */

  void cdsAlgorithm() {
    if (inputJobs.isEmpty) return;

    int numMachines = inputJobs.first.taskSequence.length;

    if (numMachines == 2) {
      _applyJohnsonRule(inputJobs);
      return;
    }

    List<FlowShopInput> bestSequence = [];
    int bestMakespan = double.maxFinite.toInt();

    for (int k = 1; k < numMachines; k++) {
      List<FlowShopInput> tempJobs = inputJobs.map((job) {
        Duration sumA = Duration.zero;
        Duration sumB = Duration.zero;

        for (int i = 0; i < k; i++) {
          int taskId = job.taskSequence[i].value1;
          sumA += job.taskTimesInMachines[taskId]!;
        }

        for (int i = k; i < numMachines; i++) {
          int taskId = job.taskSequence[i].value1;
          sumB += job.taskTimesInMachines[taskId]!;
        }

        Map<int, Duration> reducedTimes = {0: sumA, 1: sumB};

        return FlowShopInput(
          job.jobId,
          job.sequenceId,
          job.dueDate,
          job.priority,
          job.availableDate,
          [const Tuple2(0, 0), const Tuple2(1, 1)],
          reducedTimes,
        );
      }).toList();

      List<FlowShopInput> ordered = _getJohnsonOrderedJobs(tempJobs);
      List<int> orderedIds = ordered.map((e) => e.jobId).toList();

      List<FlowShopInput> orderedOriginal = orderedIds.map((id) => inputJobs.firstWhere((job) => job.jobId == id)).toList();

      int makespan = _calculateMakespan(orderedOriginal);

      if (makespan < bestMakespan) {
        bestMakespan = makespan;
        bestSequence = orderedOriginal;
      }
    }

    inputJobs = bestSequence;
    _schedule((a, b) => 0);
    print("Optimal sequence: ${bestSequence.map((job) => job.jobId).toList()}");
    print("Optimal makespan: $bestMakespan");
  }

  void _applyJohnsonRule(List<FlowShopInput> jobs) {
    List<FlowShopInput> conjuntoI = [];
    List<FlowShopInput> conjuntoII = [];

    for (var job in jobs) {
      Duration a = job.taskTimesInMachines[job.taskSequence[0].value1]!;
      Duration b = job.taskTimesInMachines[job.taskSequence[1].value1]!;
      if (a <= b) {
        conjuntoI.add(job);
      } else {
        conjuntoII.add(job);
      }
    }

    conjuntoI.sort((a, b) => a.taskTimesInMachines[a.taskSequence[0].value1]!.compareTo(b.taskTimesInMachines[b.taskSequence[0].value1]!));
    conjuntoII.sort((a, b) => b.taskTimesInMachines[b.taskSequence[1].value1]!.compareTo(a.taskTimesInMachines[a.taskSequence[1].value1]!));

    inputJobs = [...conjuntoI, ...conjuntoII];
    _schedule((a, b) => 0);
  }

  List<FlowShopInput> _getJohnsonOrderedJobs(List<FlowShopInput> jobs) {
    List<FlowShopInput> conjuntoI = [];
    List<FlowShopInput> conjuntoII = [];

    for (var job in jobs) {
      Duration a = job.taskTimesInMachines[0]!;
      Duration b = job.taskTimesInMachines[1]!;
      if (a <= b) {
        conjuntoI.add(job);
      } else {
        conjuntoII.add(job);
      }
    }

    conjuntoI.sort((a, b) => a.taskTimesInMachines[0]!.compareTo(b.taskTimesInMachines[0]!));
    conjuntoII.sort((a, b) => b.taskTimesInMachines[1]!.compareTo(a.taskTimesInMachines[1]!));
    return [...conjuntoI, ...conjuntoII];
  }

  int _calculateMakespan(List<FlowShopInput> jobSequence) {
    Map<int, DateTime> currentMachineAvailability = {};
    Map<int, String?> currentMachineState = {};

    for (var job in jobSequence) {
      for (var task in job.taskSequence) {
        int machineId = task.value2;
        currentMachineAvailability[machineId] = startDate;
        currentMachineState[machineId] = null;
      }
    }

    DateTime makespanEndTime = startDate;

    for (var job in jobSequence) {
      DateTime jobStartTime = job.availableDate;

      for (var task in job.taskSequence) {
        int taskId = task.value1;
        int machineId = task.value2;
        Duration duration = job.taskTimesInMachines[taskId]!;

        DateTime machineAvailable = currentMachineAvailability[machineId] ?? startDate;
        DateTime startTime = jobStartTime.isAfter(machineAvailable) ? jobStartTime : machineAvailable;
        startTime = _adjustForWorkingSchedule(startTime);

        // Apply sequence-dependent setup time
        final helper = setupHelpers[machineId];
        final String? prevState = currentMachineState[machineId];
        final Duration setupDuration = helper != null
            ? helper.setupDuration(prevState, job.jobState)
            : Duration.zero;

        // Setup occupies the machine before processing starts.
        final DateTime processStart =
            _adjustForWorkingSchedule(startTime.add(setupDuration));

        DateTime endTime = _calculateEndWithSchedule(processStart, duration);

        currentMachineAvailability[machineId] = endTime;
        currentMachineState[machineId] = job.jobState;
        jobStartTime = endTime;
      }

      makespanEndTime = jobStartTime.isAfter(makespanEndTime) ? jobStartTime : makespanEndTime;
    }

    return makespanEndTime.difference(startDate).inMinutes;
  }

  /* ---------- Genetic algorithm (Flow Shop sequencing) ---------- */

  void scheduleGeneticAlgorithm() {
    print("EJECUTANDO ALGORITMO GENÉTICO EN FLOW SHOP");

    const int populationSize = 50;
    const int generations = 100;
    const double mutationRate = 0.1;

    if (inputJobs.isEmpty) return;

    List<List<FlowShopInput>> population = _initializePopulation(populationSize);

    List<FlowShopInput> bestIndividual = List.from(inputJobs);
    int bestFitness = _evaluateFitnessFlowShop(bestIndividual);

    for (int generation = 0; generation < generations; generation++) {
      List<Tuple2<List<FlowShopInput>, int>> evaluated = population.map((individual) {
        return Tuple2(individual, _evaluateFitnessFlowShop(individual));
      }).toList();

      evaluated.sort((a, b) => a.value2.compareTo(b.value2));

      if (evaluated.first.value2 < bestFitness) {
        bestFitness = evaluated.first.value2;
        bestIndividual = List.from(evaluated.first.value1);
        print("Generación $generation: Mejor makespan = $bestFitness minutos");
      }

      population = _generateNewPopulation(evaluated, populationSize, mutationRate);
    }

    print("Mejor secuencia encontrada: ${bestIndividual.map((j) => j.jobId).toList()}");
    print("Makespan óptimo: $bestFitness minutos");

    inputJobs = bestIndividual;
    _schedule((a, b) => 0);
  }

  List<List<FlowShopInput>> _initializePopulation(int size) {
    List<List<FlowShopInput>> population = [];
    for (int i = 0; i < size; i++) {
      List<FlowShopInput> shuffled = List.from(inputJobs);
      shuffled.shuffle();
      population.add(shuffled);
    }
    return population;
  }

  int _evaluateFitnessFlowShop(List<FlowShopInput> jobSequence) {
    Map<int, DateTime> machineAvailability = {};
    Map<int, String?> machineState = {};

    for (var job in jobSequence) {
      for (var task in job.taskSequence) {
        int machineId = task.value2;
        machineAvailability[machineId] = startDate;
        machineState[machineId] = null;
      }
    }

    DateTime makespanEndTime = startDate;

    for (var job in jobSequence) {
      DateTime jobStartTime = job.availableDate;

      for (var task in job.taskSequence) {
        int taskId = task.value1;
        int machineId = task.value2;
        Duration duration = job.taskTimesInMachines[taskId]!;

        DateTime machineAvailable = machineAvailability[machineId] ?? startDate;
        DateTime startTime = jobStartTime.isAfter(machineAvailable) ? jobStartTime : machineAvailable;
        startTime = _adjustForWorkingSchedule(startTime);

        // Apply sequence-dependent setup time
        final helper = setupHelpers[machineId];
        final String? prevState = machineState[machineId];
        final Duration setupDuration = helper != null
            ? helper.setupDuration(prevState, job.jobState)
            : Duration.zero;

        // Setup occupies the machine before processing starts.
        final DateTime processStart =
            _adjustForWorkingSchedule(startTime.add(setupDuration));

        DateTime endTime = _calculateEndWithSchedule(processStart, duration);

        machineAvailability[machineId] = endTime;
        machineState[machineId] = job.jobState;
        jobStartTime = endTime;
      }

      if (jobStartTime.isAfter(makespanEndTime)) makespanEndTime = jobStartTime;
    }

    return makespanEndTime.difference(startDate).inMinutes;
  }

  List<List<FlowShopInput>> _generateNewPopulation(
    List<Tuple2<List<FlowShopInput>, int>> evaluated,
    int size,
    double mutationRate,
  ) {
    List<List<FlowShopInput>> newPop = [];

    for (int i = 0; i < size; i++) {
      final parent1 = _selectParent(evaluated);
      final parent2 = _selectParent(evaluated);
      List<FlowShopInput> child = _crossover(parent1, parent2);
      if (Random().nextDouble() < mutationRate) {
        child = _mutate(child);
      }
      newPop.add(child);
    }

    return newPop;
  }

  List<FlowShopInput> _selectParent(List<Tuple2<List<FlowShopInput>, int>> evaluated) {
    int k = min(5, evaluated.length);
    final selected = List.generate(k, (_) => evaluated[Random().nextInt(evaluated.length)]);
    selected.sort((a, b) => a.value2.compareTo(b.value2));
    return selected.first.value1;
  }

  List<FlowShopInput> _crossover(List<FlowShopInput> p1, List<FlowShopInput> p2) {
    final length = p1.length;
    if (length == 0) return [];

    final int point = Random().nextInt(length);
    final Set<int> jobIds = p1.sublist(0, point).map((j) => j.jobId).toSet();

    final List<FlowShopInput> child = [
      ...p1.sublist(0, point),
      ...p2.where((j) => !jobIds.contains(j.jobId)),
    ];

    // if child shorter (shouldn't) fill with remaining from p1
    if (child.length < length) {
      for (var j in p1) {
        if (!child.contains(j)) child.add(j);
        if (child.length == length) break;
      }
    }

    return child;
  }

  List<FlowShopInput> _mutate(List<FlowShopInput> individual) {
    if (individual.length < 2) return individual;
    int i = Random().nextInt(individual.length);
    int j = Random().nextInt(individual.length);
    final temp = individual[i];
    individual[i] = individual[j];
    individual[j] = temp;
    return individual;
  }
}
