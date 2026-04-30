import 'package:dartz/dartz.dart';
import 'package:production_planning/presentation/2_orders/widgets/high_order/add_job.dart';
import 'package:production_planning/services/setup_time_matrix.dart';


sealed class NewOrderState {
  NewOrderState();
}

class NewOrdersInitialState extends NewOrderState {
  NewOrdersInitialState();
}

class NewOrdersFailureState extends NewOrderState {
  NewOrdersFailureState();
}

class NewOrdersState extends NewOrderState {

  final List<AddJobWidget> jobs;
  final List<Tuple2<int, String>> sequences;
  bool? justSaved;

  final Map<String, SetupTimeMatrix> setupMatrices;
  final List<String> availableMachineNames;
 
  NewOrdersState({
    required this.jobs,
    required this.sequences,
    Map<String, SetupTimeMatrix>? setupMatrices,
    List<String>? availableMachineNames,
    this.justSaved,
  })  : setupMatrices = setupMatrices ?? {},
        availableMachineNames = availableMachineNames ?? [];
 
  NewOrdersState copyWith({
    List<AddJobWidget>? jobs,
    List<Tuple2<int, String>>? sequences,
    Map<String, SetupTimeMatrix>? setupMatrices,
    List<String>? availableMachineNames,
    bool? justSaved,
  }) => NewOrdersState(
    jobs: jobs ?? this.jobs,
    sequences: sequences ?? this.sequences,
    setupMatrices: setupMatrices ?? this.setupMatrices,
    availableMachineNames: availableMachineNames ?? this.availableMachineNames,
    justSaved: justSaved,
  );
}
