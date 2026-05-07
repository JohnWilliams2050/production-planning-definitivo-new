// lib/presentation/2_orders/pages/new_order_page.dart
//
// Fix (this version): DropdownMenuItem child used Expanded inside an
// unbounded Row, which Flutter cannot lay out and throws an infinite
// layout-error loop.  Replaced with mainAxisSize.min + plain Text.

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
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(children: jobWidgets),
                      ),
                    ),
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

  void _showMatrixDialog(
    BuildContext context,
    NewOrderState state,
    ColorScheme colorScheme,
  ) {
    if (state is! NewOrdersState) return;

    final machineNameSet = <String>{};
    for (final job in state.jobs) {
      machineNameSet
          .addAll(job.stateKey.currentState?.getMachineNames() ?? []);
    }
    final machineNames = machineNameSet.isEmpty
        ? ['(seleccione máquinas primero)']
        : (machineNameSet.toList()..sort());

    final stateSet = <String>{};
    for (final job in state.jobs) {
      stateSet.addAll(
          (job.stateKey.currentState?.getMachineFinalStates() ?? {}).values);
    }
    final jobStates = stateSet.isEmpty
        ? ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']
        : (stateSet.toList()..sort());

    showDialog(
      context: context,
      builder: (dialogContext) => _MatrixDialog(
        machineNames: machineNames,
        states: jobStates,
        existingMatrices: state.setupMatrices,
        onSave: (machineName, matrix) async {
          await BlocProvider.of<NewOrderBloc>(context)
              .saveSetupMatrix(machineName, matrix);
        },
        colorScheme: colorScheme,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Validation
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
// _MatrixDialog
// =============================================================================

class _MatrixDialog extends StatefulWidget {
  final List<String> machineNames;
  final List<String> states;
  final Map<String, SetupTimeMatrix> existingMatrices;
  final Future<void> Function(String machineName, SetupTimeMatrix matrix)
      onSave;
  final ColorScheme colorScheme;

  const _MatrixDialog({
    required this.machineNames,
    required this.states,
    required this.existingMatrices,
    required this.onSave,
    required this.colorScheme,
  });

  @override
  State<_MatrixDialog> createState() => _MatrixDialogState();
}

class _MatrixDialogState extends State<_MatrixDialog> {
  late String _selectedMachine;
  late final Map<String, SetupTimeMatrix> _matrices;
  late List<List<TextEditingController>> _controllers;

  final Set<String> _savedMachines = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedMachine = widget.machineNames.first;

    _matrices = {};
    for (final name in widget.machineNames) {
      final existing = widget.existingMatrices[name];
      if (existing != null) {
        _matrices[name] = _copyMatrix(existing);
        _savedMachines.add(name);
      } else {
        _matrices[name] =
            SetupTimeMatrix(machineName: name, states: widget.states);
      }
    }

    _buildControllers(_selectedMachine);
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  SetupTimeMatrix _copyMatrix(SetupTimeMatrix src) {
    final copy = SetupTimeMatrix(
        machineName: src.machineName, states: src.states.toList());
    for (int r = 0; r < src.states.length; r++) {
      for (int c = 0; c < src.states.length; c++) {
        copy.setTimeByIndex(r, c, src.getTimeByIndex(r, c));
      }
    }
    return copy;
  }

  void _buildControllers(String machine) {
    final matrix = _matrices[machine]!;
    _controllers = List.generate(
      widget.states.length,
      (r) => List.generate(widget.states.length, (c) {
        final val = matrix.getTimeByIndex(r, c);
        return TextEditingController(
            text: val == 0.0 ? '' : val.toStringAsFixed(1));
      }),
    );
  }

  void _disposeControllers() {
    for (final row in _controllers) {
      for (final ctrl in row) ctrl.dispose();
    }
  }

  void _flushToModel() {
    final matrix = _matrices[_selectedMachine]!;
    for (int r = 0; r < widget.states.length; r++) {
      for (int c = 0; c < widget.states.length; c++) {
        final raw = _controllers[r][c].text.trim();
        final val = (double.tryParse(raw) ?? 0.0).clamp(0.0, double.infinity);
        matrix.setTimeByIndex(r, c, val);
      }
    }
  }

  void _switchMachine(String name) {
    _flushToModel();
    _disposeControllers();
    setState(() {
      _selectedMachine = name;
      _buildControllers(name);
    });
  }

  Future<void> _saveCurrentMachine() async {
    _flushToModel();
    setState(() => _isSaving = true);

    await widget.onSave(_selectedMachine, _matrices[_selectedMachine]!);

    if (!mounted) return;
    setState(() {
      _savedMachines.add(_selectedMachine);
      _isSaving = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Matriz guardada para "$_selectedMachine"'),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Matriz de tiempos de alistamiento"),
      content: SizedBox(
        width: double.maxFinite,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── machine selector ──────────────────────────────────────────
            // FIX: DropdownMenuItem renders inside an UNBOUNDED width context.
            // Using Expanded here causes "RenderFlex children have non-zero
            // flex but incoming width constraints are unbounded."
            // Solution: mainAxisSize.min on the Row + no Expanded child.
            DropdownButtonFormField<String>(
              value: _selectedMachine,
              decoration: const InputDecoration(labelText: 'Máquina'),
              isExpanded: true, // constrain the button itself, not the item Row
              items: widget.machineNames.map((m) {
                final isSaved = _savedMachines.contains(m);
                return DropdownMenuItem<String>(
                  value: m,
                  child: Row(
                    // ← mainAxisSize.min: Row only takes as much space as
                    //   its children need; no child may use Expanded here.
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m),
                      if (isSaved) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 16),
                      ],
                    ],
                  ),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) _switchMachine(v);
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Tiempo en minutos para cambiar del tipo de la FILA '
              'al tipo de la COLUMNA. Diagonal = 0 (mismo tipo).',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: _buildTable(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Resetear
        TextButton(
          onPressed: () {
            setState(() {
              for (final row in _controllers) {
                for (final ctrl in row) ctrl.text = '';
              }
              _matrices[_selectedMachine] = SetupTimeMatrix(
                  machineName: _selectedMachine, states: widget.states);
              _savedMachines.remove(_selectedMachine);
            });
          },
          child: const Text("Resetear"),
        ),

        // Guardar
        ElevatedButton.icon(
          onPressed: _isSaving ? null : _saveCurrentMachine,
          icon: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save, size: 18),
          label: const Text("Guardar"),
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.colorScheme.primary,
            foregroundColor: widget.colorScheme.onPrimary,
          ),
        ),

        // Cerrar
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cerrar"),
        ),
      ],
    );
  }

  // ── grid table ────────────────────────────────────────────────────────────

  DataTable _buildTable() {
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
          ...List.generate(widget.states.length, (c) {
            final isDiagonal = r == c;
            return DataCell(
              SizedBox(
                width: 52,
                child: TextField(
                  controller: _controllers[r][c],
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
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 4),
                    filled: isDiagonal,
                    fillColor: isDiagonal ? Colors.grey.shade200 : null,
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