import 'dart:convert';

class SetupTimeMatrixEntry{
  final String fromState;
  final String toState;
  final double time;

  const SetupTimeMatrixEntry({
    required this.fromState,
    required this.toState,
    required this.time,
  });

  @override
  String toString() {
    return 'SetupTimeMatrixEntry(fromState: $fromState, toState: $toState, time: $time)';
  }
}

class SetupTimeMatrix{
  final String machineName;
  final List<String> states;
  final Map<String, Map<String, double>> _data = {};

  SetupTimeMatrix({
    required this.machineName,
    required List<String> states,
  }) : states = List.unmodifiable(states){
    _initDefaultTimes();
  }

  //Initialize the matrix with default times (0.0) for all state transitions
  void _initDefaultTimes(){
    for (var fromState in states) {
      _data[fromState] = {};
      for (var toState in states) {
        _data[fromState]![toState] = 0.0;
      }
    }
  }

  //Set the setup time for a specific state transition
  void setTime(String fromState, String toState, double time){
    if(_data.containsKey(fromState) && _data[fromState]!.containsKey(toState)){
      if(time < 0){
        throw ArgumentError('Time cannot be negative: $time');
      }
      _data[fromState]![toState] = time;
    } else {
      throw ArgumentError('Invalid states: $fromState -> $toState');
    }
  }
  //Same thing as above but accessed with indexes instead of state names
  void setTimeByIndex(int rowIndex, int colIndex, double time){
    setTime(states[rowIndex], states[colIndex], time);
  }

  //get the setup time for a specific state transition
  double getTime(String fromState, String toState){
    if(fromState == null) return 0.0;
    if(_data.containsKey(fromState) && _data[fromState]!.containsKey(toState)){
      return _data[fromState]?[toState] ?? 0.0;
    } else {
      throw ArgumentError('Invalid states: $fromState -> $toState');
    }
  }
  //Same thing as above but accessed with indexes instead of state names
  double getTimeByIndex(int rowIndex, int colIndex){
    return getTime(states[rowIndex], states[colIndex]);
  }
  //Get a list of all non-zero entries in the matrix
  List<SetupTimeMatrixEntry> get nonZeroEntries {
    final result = <SetupTimeMatrixEntry>[];
    for (final from in states) {
      for (final to in states) {
        final t = _data[from]![to]!;
        if (t != 0.0) {
          result.add(SetupTimeMatrixEntry(
            fromState: from,
            toState: to,
            time: t,
          ));
        }
      }
    }
    return result;
  }

  //get all entries in the matrix as a list of SetupTimeMatrixEntry
  List<SetupTimeMatrixEntry> get allEntries {
    final result = <SetupTimeMatrixEntry>[];
    for (final from in states) {
      for (final to in states) {
        final t = _data[from]![to]!;
        result.add(SetupTimeMatrixEntry(
          fromState: from,
          toState: to,
          time: t,
        ));
      }
    }
    return result;
  }
}

class SetupTimeHelper{
  final SetupTimeMatrix _matrix;
  SetupTimeHelper(this._matrix);

  //returns the setup time for a transition from state A to state B on the machine associated with the matrix
  double getSetupTime(String? fromState, String toState){
    return _matrix.getTime(fromState!, toState);
  }
  //calculates the start time of toState given the end time of fromState and the setup time between them
  double startTime(double completionTimeOfFromJob, String fromJobState, String toJobState){
    return completionTimeOfFromJob + getSetupTime(fromJobState, toJobState);
  }

  //returns the effective processing time of [toJobState] given it follows [fromJobState], for algorithms that incorporate setup into processing.
  double effectiveProcessingTime(double nominalProcessingTime, String fromJobState, toJobState){
    return nominalProcessingTime + getSetupTime(fromJobState, toJobState);
  }

  //given an ordered sequence of [jobState] (the output of a scheduling algorithm)
  //computes the total setup time for the whole sequence.
  double totalSetupTime(List<String> jobStates){
    if(jobStates.length < 2) return 0.0;
    double total = 0.0;
    total += getSetupTime(null, jobStates.first);
    for (int i = 0; i < jobStates.length-1; i++) {
      total += getSetupTime(jobStates[i], jobStates[i+1]);
    }
    return total;
  }
  
}
