// =============================================================================
// lib/presentation/2_orders/pages/new_order_page.dart
//
// Changes from the previous static version:
//   1. The matrix dialog is now driven by SetupTimeMatrix / SetupTimeHelper.
//   2. Machine list comes from NewOrderBloc (already has machine data).
//   3. Cells are backed by TextEditingControllers that read/write the matrix.
//   4. On "Cerrar" the filled matrix is dispatched back to the BLoC so it can
//      be persisted via SetupTimeDao before running an algorithm.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:production_planning/presentation/2_orders/bloc/new_order_bloc/new_order_bloc.dart';
import 'package:production_planning/presentation/2_orders/bloc/new_order_bloc/new_order_state.dart';
import 'package:production_planning/presentation/2_orders/widgets/high_order/add_job.dart';
import 'package:production_planning/services/setup_time_matrix.dart';
import 'package:production_planning/shared/functions/functions.dart';

class NewOrderPage extends StatelessWidget {
  const NewOrderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Crear Nuevo Programa de Produccion'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: BlocListener<NewOrderBloc, NewOrderState>(
          listener: (context, state) {
            if (state is NewOrdersState && state.justSaved != null) {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (subcontext) => AlertDialog(
                  title: Text(
                    state.justSaved! ? "Guardado!!" : "Error",
                    style: TextStyle(
                      color: state.justSaved!
                          ? colorScheme.primary
                          : colorScheme.error,
                    ),
                  ),
                  content: Text(
                    state.justSaved!
                        ? "La orden ha sido guardada exitosamente"
                        : "Hubo un error guardando la orden",
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(subcontext).pop();
                        Navigator.of(context).pop(state.justSaved);
                      },
                      child: const Text("OK"),
                    ),
                  ],
                ),
              );
            }
          },
          child: BlocBuilder<NewOrderBloc, NewOrderState>(
            builder: (context, state) {
              final bloc = BlocProvider.of<NewOrderBloc>(context);

              if (state is NewOrdersInitialState) {
                bloc.retrieveSequences();
                return const Center(child: CircularProgressIndicator());
              }

              final List<AddJobWidget> jobWidgets =
                  state is NewOrdersState ? state.jobs : [];

              return Center(
                child: Column(
                  children: [
                    // ── info button ─────────────────────────────────────────
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.info),
                          onPressed: () => printInfo(
                            context,
                            title: 'Crear orden',
                            content:
                                'La creacion de una orden implica seleccionar '
                                'los productos que deben ser fabricados, la '
                                'prioridad que se tiene para fabricarlos, desde '
                                'cuando se tiene la disponibilidad para '
                                'fabricarlos (por ejemplo, por insumos), y cual '
                                'es la fecha limite.\n\nUn producto esta '
                                'relacionado con una secuencia, pues una '
                                'secuencia es la secuencia de produccion para '
                                'producir un producto.',
                          ),
                        ),
                      ],
                    ),
                    // ── job list ─────────────────────────────────────────────
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(children: jobWidgets),
                      ),
                    ),
                    // ── action buttons ───────────────────────────────────────
                    ElevatedButton(
                      onPressed: () => bloc.addJob(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Agregar Job'),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () =>
                          _showMatrixDialog(context, state, colorScheme),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text(
                          'Definir matriz de tiempos de alistamiento'),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        if (!_validateForm(state)) {
                          _showValidationDialog(context, colorScheme);
                        } else {
                          bloc.saveOrder();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.secondary,
                        foregroundColor: colorScheme.onSecondary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Crear programa de produccion'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Matrix dialog
  // ---------------------------------------------------------------------------

  /// Opens the "Matriz de tiempos de alistamiento" dialog.
  ///
  /// The dialog is stateful so cell edits persist while it is open.
  /// On "Cerrar" the completed matrix is dispatched to [NewOrderBloc] via
  /// [NewOrderBloc.saveSetupMatrix], which persists it through SetupTimeDao.
  void _showMatrixDialog(
    BuildContext context,
    NewOrderState state,
    ColorScheme colorScheme,
  ) {
    // ── derive the list of machines from bloc state ──────────────────────────
    // NewOrdersState exposes the machines involved in the current order.
    // Fall back to an empty list so the dialog can still open gracefully.
    final List<String> machineNames =
        state is NewOrdersState ? state.availableMachineNames : [];

    // ── derive job states (product families) from current jobs ───────────────
    // These are the "Estado dejado en la maquina" values across all jobs.
    // They define the row/column labels of the matrix.
    final List<String> jobStates = state is NewOrdersState
        ? state.jobs
            .map((j) => j.selectedMachineState)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort()
        : ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'];

    // If no job states are defined yet, use the default A-J set so the user
    // can still pre-fill the matrix before all jobs are configured.
    final labels = jobStates.isEmpty
        ? ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']
        : jobStates;

    showDialog(
      context: context,
      builder: (dialogContext) => _MatrixDialog(
        machineNames: machineNames.isEmpty ? ['(sin máquinas)'] : machineNames,
        states: labels,
        // Pass any matrix that was already saved for the first machine so the
        // user sees their previous values when re-opening the dialog.
        initialMatrix: state is NewOrdersState
            ? state.setupMatrices[machineNames.isNotEmpty ? machineNames.first : '']
            : null,
        onSave: (machineName, matrix) {
          // Dispatch to BLoC → service → DAO → SQLite.
          BlocProvider.of<NewOrderBloc>(context)
              .saveSetupMatrix(machineName, matrix);
        },
        colorScheme: colorScheme,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Validation helpers (unchanged)
  // ---------------------------------------------------------------------------

  bool _validateForm(NewOrderState state) {
    if (state is NewOrdersState && state.jobs.isNotEmpty) {
      for (final job in state.jobs) {
        if (job.priorityController?.text.isEmpty ?? true) return false;
        if (job.quantityController?.text.isEmpty ?? true) return false;
        if (job.availableDate == null) return false;
        if (job.dueDate == null) return false;
        if (job.selectedSequence == null) return false;
      }
      return true;
    }
    return false;
  }

  void _showValidationDialog(BuildContext context, ColorScheme colorScheme) {
    showDialog(
      context: context,
      builder: (subcontext) => AlertDialog(
        title: Text("Campos Incompletos",
            style: TextStyle(color: colorScheme.error)),
        content: const Text(
            "Asegúrese de llenar todos los campos de todos los jobs "
            "antes de crear el programa de producción."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(subcontext).pop(),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _MatrixDialog — stateful widget that owns the matrix editing UI
// =============================================================================

class _MatrixDialog extends StatefulWidget {
  final List<String> machineNames;
  final List<String> states;
  final SetupTimeMatrix? initialMatrix;
  final void Function(String machineName, SetupTimeMatrix matrix) onSave;
  final ColorScheme colorScheme;

  const _MatrixDialog({
    required this.machineNames,
    required this.states,
    required this.onSave,
    required this.colorScheme,
    this.initialMatrix,
  });

  @override
  State<_MatrixDialog> createState() => _MatrixDialogState();
}

class _MatrixDialogState extends State<_MatrixDialog> {
  late String _selectedMachine;

  /// One matrix per machine — keeps edits alive when the user switches machines.
  late final Map<String, SetupTimeMatrix> _matrices;

  /// TextEditingControllers for every cell of the CURRENTLY visible matrix.
  /// Rebuilt whenever [_selectedMachine] changes.
  late List<List<TextEditingController>> _controllers;

  @override
  void initState() {
    super.initState();
    _selectedMachine = widget.machineNames.first;

    // Pre-populate matrices map with any already-saved matrix.
    _matrices = {};
    for (final name in widget.machineNames) {
      _matrices[name] = SetupTimeMatrix(
        machineName: name,
        states: widget.states,
      );
    }
    if (widget.initialMatrix != null) {
      _matrices[_selectedMachine] = widget.initialMatrix!;
    }

    _buildControllers(_selectedMachine);
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  // ── controller management ─────────────────────────────────────────────────

  void _buildControllers(String machineName) {
    final matrix = _matrices[machineName]!;
    _controllers = List.generate(
      widget.states.length,
      (r) => List.generate(widget.states.length, (c) {
        final val = matrix.getTimeByIndex(r, c);
        return TextEditingController(
          text: val == 0.0 ? '' : val.toStringAsFixed(1),
        );
      }),
    );
  }

  void _disposeControllers() {
    for (final row in _controllers) {
      for (final ctrl in row) {
        ctrl.dispose();
      }
    }
  }

  /// Flushes the current controller values into the matrix model.
  void _flushControllers() {
    final matrix = _matrices[_selectedMachine]!;
    for (int r = 0; r < widget.states.length; r++) {
      for (int c = 0; c < widget.states.length; c++) {
        final raw = _controllers[r][c].text.trim();
        final parsed = double.tryParse(raw) ?? 0.0;
        final safeVal = parsed < 0 ? 0.0 : parsed;
        matrix.setTimeByIndex(r, c, safeVal);
      }
    }
  }

  void _switchMachine(String newMachine) {
    _flushControllers(); // save edits for the old machine
    _disposeControllers();
    setState(() {
      _selectedMachine = newMachine;
      _buildControllers(newMachine);
    });
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Matriz de tiempos de alistamiento"),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── machine selector ────────────────────────────────────────────
            DropdownButtonFormField<String>(
              value: _selectedMachine,
              decoration: const InputDecoration(labelText: 'Máquina'),
              items: widget.machineNames
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (value) {
                if (value != null) _switchMachine(value);
              },
            ),
            const SizedBox(height: 12),
            // ── explanation text ────────────────────────────────────────────
            Text(
              'Ingrese el tiempo de alistamiento (en minutos) al pasar '
              'del tipo de job de la FILA al tipo de job de la COLUMNA.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            // ── scrollable grid ─────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: _buildDataTable(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Reset button — zeros all cells for the current machine.
        TextButton(
          onPressed: () {
            setState(() {
              for (final row in _controllers) {
                for (final ctrl in row) {
                  ctrl.text = '';
                }
              }
              _matrices[_selectedMachine] = SetupTimeMatrix(
                machineName: _selectedMachine,
                states: widget.states,
              );
            });
          },
          child: const Text("Resetear"),
        ),
        TextButton(
          onPressed: () {
            // Flush current edits into the model, then persist each matrix.
            _flushControllers();
            for (final entry in _matrices.entries) {
              widget.onSave(entry.key, entry.value);
            }
            Navigator.of(context).pop();
          },
          child: const Text("Cerrar"),
        ),
      ],
    );
  }

  DataTable _buildDataTable() {
    return DataTable(
      columnSpacing: 8,
      headingRowHeight: 36,
      dataRowMinHeight: 44,
      dataRowMaxHeight: 44,
      columns: [
        const DataColumn(label: SizedBox(width: 24, child: Text(''))),
        ...widget.states.map(
          (label) => DataColumn(
            label: SizedBox(
              width: 52,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ],
      rows: List.generate(widget.states.length, (r) {
        return DataRow(cells: [
          // Row header
          DataCell(
            SizedBox(
              width: 24,
              child: Text(
                widget.states[r],
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          // One cell per column
          ...List.generate(widget.states.length, (c) {
            final isDiagonal = r == c;
            return DataCell(
              SizedBox(
                width: 52,
                child: TextField(
                  controller: _controllers[r][c],
                  // Diagonal cells are typically 0 but still editable.
                  enabled: !isDiagonal,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDiagonal ? Colors.grey : null,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: isDiagonal ? '0' : null,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    filled: isDiagonal,
                    fillColor:
                        isDiagonal ? Colors.grey.shade200 : null,
                  ),
                ),
              ),
            );
          }),
        ]);
      }),
    );
  }
}