// lib/services/adapters/single_machine_adapter.dart
//
// Changes from previous version:
//   • Passes job.jobState into each SingleMachineInput.
//   • Builds a SetupTimeHelper from SetupTimeService and passes it to
//     SingleMachine as the optional setupHelper parameter.
//   • Everything else is identical.

import 'package:dartz/dartz.dart';
import 'package:production_planning/dependency_injection.dart';
import 'package:production_planning/entities/metrics.dart';
import 'package:production_planning/entities/order_entity.dart';
import 'package:production_planning/entities/planning_machine_entity.dart';
import 'package:production_planning/entities/planning_task_entity.dart';
import 'package:production_planning/services/algorithms/single_machine.dart';
import 'package:production_planning/repositories/interfaces/machine_repository.dart';
import 'package:production_planning/repositories/interfaces/order_repository.dart';
import 'package:production_planning/services/adapters/metrics.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
import 'package:production_planning/services/setup_time_service.dart';
import 'package:production_planning/shared/functions/functions.dart';

import '../../entities/machine_entity.dart';
import '../../shared/utils/task_time_utils.dart';

class SingleMachineAdapter {
  final OrderRepository orderRepository;
  final MachineRepository machineRepository;
  final SetupTimeService setupTimeService; // <── new

  SingleMachineAdapter({
    required this.orderRepository,
    required this.machineRepository,
    required this.setupTimeService, // <── injected
  });

  Future<Tuple2<List<PlanningMachineEntity>, Metrics>?> singleMachineAdapter(
      int orderId, String rule) async {
    // ── 1. Load order ────────────────────────────────────────────────────────
    final responseOrder = await orderRepository.getFullOrder(orderId);
    final OrderEntity? order =
        responseOrder.fold((f) => null, (o) => o);
    if (order == null) return null;

    // ── 2. Resolve the single machine ────────────────────────────────────────
    final int machineTypeId =
        order.orderJobs![0].sequence!.tasks![0].machineTypeId;
    final responseMachine =
        await machineRepository.getAllMachinesFromType(machineTypeId);
    final MachineEntity? machineEntity =
        responseMachine.fold((f) => null, (m) => m[0]);
    if (machineEntity == null) return null;

    final responseTypeMachine =
        await machineRepository.getMachineTypeName(machineTypeId);
    final String machineTypeName =
        responseTypeMachine.fold((f) => "", (name) => name);

    // ── 3. Build setup-time helper for this machine ──────────────────────────
    // We collect the distinct job states used in this order so the matrix
    // dimensions match what was entered in the dialog.
    final Set<String> jobStates = order.orderJobs!
        .map((j) => j.jobState ?? 'A') // jobState comes from the order entity
        .toSet();
    final helpers = await setupTimeService.buildHelpersForMachines(
      machineIdsAndNames: {machineEntity.id!: machineEntity.name},
      jobStates: jobStates.toList()..sort(),
    );
    final SetupTimeHelper? helper = helpers[machineEntity.id!];

    // ── 4. Build input list ──────────────────────────────────────────────────
    final List<SingleMachineInput> inputList = [];
    for (final job in order.orderJobs!) {
      final taskId = job.sequence!.tasks![0].id!;
      final explicit =
          getExplicitProcessingDuration(job, taskId, machineEntity);
      final baseDuration = Duration(
          minutes: (60 * machineEntity.processingPercentage / 100).round());
      final Duration duration = explicit ??
          ruleOf3(baseDuration, job.sequence!.tasks![0].processingUnits);

      for (var i = 0; i < job.amount; i++) {
        inputList.add(SingleMachineInput(
          job.jobId!,
          duration,
          job.dueDate,
          job.priority,
          job.availableDate,
          jobState: job.jobState ?? 'A', // <── pass state to algorithm
        ));
      }
    }

    // ── 5. Run algorithm ─────────────────────────────────────────────────────
    final output = SingleMachine(
      0,
      order.regDate,
      Tuple2(START_SCHEDULE, END_SCHEDULE),
      inputList,
      rule,
      setupHelper: helper, // <── inject setup times
    ).output;

    // ── 6. Map output → PlanningTaskEntity (unchanged) ───────────────────────
    final Map<int, int> jobCounter = {};
    final tasks = output.map((out) {
      final jobSequence = order.orderJobs!
          .firstWhere((job) => job.jobId == out.jobId)
          .sequence!;
      final job = order.orderJobs!.firstWhere((j) => j.jobId == out.jobId);
      final current = (jobCounter[out.jobId] ?? 0) + 1;
      jobCounter[out.jobId] = current;
      final jobName = job.jobName ?? 'Job ${out.jobId}';
      final displayName = current == 1 ? jobName : '$jobName (${current - 1})';
      return PlanningTaskEntity(
        sequenceId: jobSequence.id!,
        sequenceName: jobSequence.name,
        displayName: displayName,
        taskId: jobSequence.tasks![0].id!,
        numberProcess: 1,
        startDate: out.startDate,
        endDate: out.endDate,
        retarded: out.dueDate.isBefore(out.endDate),
        jobId: out.jobId,
        orderId: orderId,
      );
    }).toList();

    final machinesResult = [
      PlanningMachineEntity(
        machineEntity.id!,
        machineTypeName,
        tasks,
        scheduledInactivities: machineEntity.scheduledInactivities,
      )
    ];

    final metrics = getMetricts(
      machinesResult,
      output.map((out) {
        final job = order.orderJobs!.firstWhere((j) => j.jobId == out.jobId);
        return Tuple4(out.startDate, out.endDate, out.dueDate, job.priority);
      }).toList(),
    );

    return Tuple2(machinesResult, metrics);
  }
}