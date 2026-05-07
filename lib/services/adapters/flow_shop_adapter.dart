import 'package:dartz/dartz.dart';
import 'package:production_planning/dependency_injection.dart';
import 'package:production_planning/entities/metrics.dart';
import 'package:production_planning/entities/order_entity.dart';
import 'package:production_planning/entities/planning_machine_entity.dart';
import 'package:production_planning/entities/planning_task_entity.dart';
import 'package:production_planning/repositories/interfaces/machine_repository.dart';
import 'package:production_planning/repositories/interfaces/order_repository.dart';
import 'package:production_planning/services/adapters/metrics.dart';
import 'package:production_planning/services/algorithms/flow_shop.dart';
import 'package:production_planning/services/setup_time_service.dart';
import 'package:production_planning/shared/functions/functions.dart';
import '../../entities/machine_entity.dart';
import '../../shared/utils/task_time_utils.dart';

class FlowShopAdapter {
  final OrderRepository orderRepository;
  final MachineRepository machineRepository;
  final SetupTimeService setupTimeService;

  FlowShopAdapter({
    required this.orderRepository,
    required this.machineRepository,
    required this.setupTimeService,
  });

  Future<Tuple2<List<PlanningMachineEntity>, Metrics>?> flowShopAdapter(
    int orderId,
    String rule,
  ) async {
    final responseOrder = await orderRepository.getFullOrder(orderId);
    OrderEntity? order = responseOrder.fold((f) => null, (or) => or);
    if (order == null) return null;

    //We get all machines
    final List<int> machinesTypesIds = order.orderJobs![0].sequence!.tasks!
        .map((t) => t.machineTypeId)
        .toList();
    final List<MachineEntity> machines = [];
    for (final typeId in machinesTypesIds) {
      final machinesSpecific =
          await machineRepository.getAllMachinesFromType(typeId);
      final machineList = machinesSpecific.fold((_) => null, (m) => m);
      if (machineList == null || machineList.isEmpty) return null;
      machines.addAll(machineList);
    }

    // Collect job states for setup time matrices
    final Set<String> jobStates = order.orderJobs!
        .map((j) => j.jobState ?? 'A')
        .toSet();

    // Build setup helpers for machine types (since flow shop uses machineTypeId as machineId)
    final Map<int, String> machineTypeIdsAndNames = {};
    for (final machine in machines) {
      if (machine.machineTypeId != null) {
        machineTypeIdsAndNames.putIfAbsent(machine.machineTypeId!, () => machine.name);
      }
    }
    final setupHelpers = await setupTimeService.buildHelpersForMachines(
      machineIdsAndNames: machineTypeIdsAndNames,
      jobStates: jobStates.toList()..sort(),
    );

    //we create the input and expand jobs by their `amount` (cantidad)
    final List<FlowShopInput> inputJobs = [];
    for (final job in order.orderJobs!) {
      final Map<int, Duration> taskTimes = {};
      final List<Tuple2<int, int>> taskSequence = [];
      //iterating over all tasks, and for each one, we get the time it takes on the machine we have for the machine type
      for (final task in job.sequence!.tasks!) {
        final machineOfTask =
            machines.where((m) => m.machineTypeId == task.machineTypeId).first;
        // Prefer explicit job-task-machine time when present (robust)
        final explicit =
            getExplicitProcessingDuration(job, task.id!, machineOfTask);
        // Calculate duration from machine percentage (100% = 1 hour base)
        final baseDuration = Duration(
            minutes: (60 * machineOfTask.processingPercentage / 100).round());
        taskTimes[task.id!] =
            explicit ?? ruleOf3(baseDuration, task.processingUnits);
        taskSequence.add(Tuple2(task.id!, task.machineTypeId));
      }
      for (var i = 0; i < job.amount; i++) {
        inputJobs.add(FlowShopInput(
          job.jobId!,
          job.sequence!.id!,
          job.dueDate,
          job.priority,
          job.availableDate,
          taskSequence,
          taskTimes,
          jobState: job.jobState ?? 'A',
        ));
      }
    }

    //we create the sequence
    final Map<int, DateTime> machinesAvailability = {};
    for (final task in order.orderJobs!.first.sequence!.tasks!) {
      machinesAvailability[task.machineTypeId] = DateTime.now();
    }

    //we call the algorithm and receive the output
    final output = FlowShop(
      order.regDate,
      Tuple2(START_SCHEDULE, END_SCHEDULE),
      inputJobs,
      machinesAvailability,
      rule,
      setupHelpers: setupHelpers,
    ).output;

    //transform to planning machines
    final List<PlanningMachineEntity> planningMachines = [];
    for (final m in machines) {
      planningMachines.add(PlanningMachineEntity(
        m.machineTypeId!,
        m.name,
        [],
        scheduledInactivities: m.scheduledInactivities,
      ));
    }

    final Map<int, int> jobCounter = {};
    for (final out in output) {
      int i = 0;
      final job = order.orderJobs!.where((j) => j.jobId == out.jobId).first;
      final jobSequence = job.sequence!;
      final current = (jobCounter[out.jobId] ?? 0) + 1;
      jobCounter[out.jobId] = current;
      final jobName = job.jobName ?? 'Job ${out.jobId}';
      final displayName = current == 1
          ? jobName
          : '$jobName (${current - 1})';
      for (final machineScheduling in out.machinesScheduling.entries) {
        //we get the planning machine where this task belongs
        final planningMachineEntity = planningMachines
            .where((pm) => pm.machineId == machineScheduling.key)
            .first;
        final DateTime taskStart = machineScheduling.value.value2.startDate;
        final DateTime taskEnd = machineScheduling.value.value2.endDate;
        final planningTask = PlanningTaskEntity(
            sequenceId: jobSequence.id!,
            sequenceName: jobSequence.name,
            displayName: displayName,
            taskId: machineScheduling.value.value1,
            numberProcess: i++,
            startDate: taskStart,
            endDate: taskEnd,
            retarded: out.dueDate.isBefore(out.endTime),
            orderId: orderId,
            jobId: out.jobId);

        planningMachineEntity.tasks.add(planningTask);
      }
    }
    //we get the metrics

    final List<Tuple4<DateTime, DateTime, DateTime, int>> jobsDates = [];
    for (final out in output) {
      final job = order.orderJobs!.firstWhere((j) => j.jobId == out.jobId);
      jobsDates
          .add(Tuple4(out.startDate, out.endTime, out.dueDate, job.priority));
    }

    final metrics = getMetricts(
      planningMachines,
      jobsDates,
    );
    return Tuple2(planningMachines, metrics);
  }
}
