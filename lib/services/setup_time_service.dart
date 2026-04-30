import 'package:dartz/dartz.dart';
import 'package:production_planning/core/errors/failure.dart';
import 'package:production_planning/daos/interfaces/setup_time_dao.dart';
import 'package:production_planning/entities/setup_time_entity.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
 
class SetupTimeService {
  final SetupTimeDao _dao;
  final Map<String, SetupTimeMatrix> _matrixCache = {};
 
  SetupTimeService(this._dao);
 
  // ---------------------------------------------------------------------------
  // In-memory matrix support for the order-creation matrix dialog
  // ---------------------------------------------------------------------------
  Future<void> saveMatrix(String machineName, SetupTimeMatrix matrix) async {
    _matrixCache[machineName] = matrix;
  }
 
  Future<SetupTimeMatrix> loadMatrix({
    required String machineName,
    required List<String> jobStates,
  }) async {
    return _matrixCache[machineName] ??
        SetupTimeMatrix(machineName: machineName, states: jobStates);
  }
 
  Future<Map<int, SetupTimeHelper>> buildHelpersForMachines({
    required Map<int, String> machineIdsAndNames,
    required List<String> jobStates,
  }) async {
    final helpers = <int, SetupTimeHelper>{};
    for (final entry in machineIdsAndNames.entries) {
      final matrix = await loadMatrix(
        machineName: entry.value,
        jobStates: jobStates,
      );
      helpers[entry.key] = SetupTimeHelper(matrix);
    }
    return helpers;
  }
 
  // ---------------------------------------------------------------------------
  // Persistent sequence-dependent setup time CRUD for SetupTimesPage
  // ---------------------------------------------------------------------------
  Future<Either<Failure, List<SetupTimeEntity>>> getSetupTimesByMachine(
      int machineId) {
    return _dao.getAllByMachine(machineId);
  }
 
  Future<Either<Failure, int>> addSetupTime({
    required int machineId,
    int? fromSequenceId,
    required int toSequenceId,
    required Duration setupDuration,
  }) {
    final setupTime = SetupTimeEntity(
      machineId: machineId,
      fromSequenceId: fromSequenceId,
      toSequenceId: toSequenceId,
      setupDuration: setupDuration,
    );
    return _dao.insert(setupTime);
  }
 
  Future<Either<Failure, bool>> deleteSetupTime(int id) {
    return _dao.delete(id);
  }
 
  Future<Either<Failure, bool>> updateSetupTime(SetupTimeEntity setupTime) {
    return _dao.update(setupTime);
  }
 
  Future<Either<Failure, SetupTimeEntity?>> getSetupTime(
    int machineId,
    int? fromSequenceId,
    int toSequenceId,
  ) {
    return _dao.getSetupTime(machineId, fromSequenceId, toSequenceId);
  }
 
  // ---------------------------------------------------------------------------
  // Build changeover matrix for scheduling algorithms
  // ---------------------------------------------------------------------------
  /// Builds a changeover time matrix from the database for use in scheduling.
  /// 
  /// Returns: Map<machineId, Map<fromSequenceId, Map<toSequenceId, Duration>>>
  /// where fromSequenceId can be null for cold-start (initial setup).
  Future<Either<Failure, Map<int, Map<int?, Map<int, Duration>>>>> buildChangeoverMatrix() async {
    final allResult = await _dao.getAll();
    
    return allResult.fold(
      (failure) => Left(failure),
      (setupTimeEntities) {
        final matrix = <int, Map<int?, Map<int, Duration>>>{};
        
        for (final entity in setupTimeEntities) {
          // Initialize machine entry if not present
          matrix.putIfAbsent(entity.machineId, () => {});
          
          // Initialize fromSequenceId entry if not present
          matrix[entity.machineId]!.putIfAbsent(entity.fromSequenceId, () => {});
          
          // Add the setup duration for this transition
          matrix[entity.machineId]![entity.fromSequenceId]![entity.toSequenceId] = 
              entity.setupDuration;
        }
        
        return Right(matrix);
      },
    );
  }
}

