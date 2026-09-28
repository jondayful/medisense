import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Month/year picker for dates printed without a day on medicine packaging.
Future<DateTime?> showExpiryMonthPicker(
  BuildContext context, {
  DateTime? initialDate,
  bool largeText = false,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) => _ExpiryMonthDialog(
    initialDate: initialDate ?? DateTime.now(),
    largeText: largeText,
  ),
);

class _ExpiryMonthDialog extends StatefulWidget {
  const _ExpiryMonthDialog({
    required this.initialDate,
    required this.largeText,
  });

  final DateTime initialDate;
  final bool largeText;

  @override
  State<_ExpiryMonthDialog> createState() => _ExpiryMonthDialogState();
}

class _ExpiryMonthDialogState extends State<_ExpiryMonthDialog> {
  late final TextEditingController _yearController;
  late int _selectedMonth;

  @override
  void initState() {
    super.initState();
    _yearController = TextEditingController(
      text: widget.initialDate.year.toString(),
    );
    _selectedMonth = widget.initialDate.month;
  }

  @override
  void dispose() {
    _yearController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accessible = widget.largeText;
    final year = int.tryParse(_yearController.text);
    final validYear = year != null && year >= 2000 && year <= 2100;
    return AlertDialog(
      title: Text(
        'Expiration month',
        style: TextStyle(fontSize: accessible ? 27 : 24),
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose the month and year printed on the label.',
                style: TextStyle(fontSize: accessible ? 19 : 16, height: 1.35),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _yearController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: InputDecoration(
                  labelText: 'Year',
                  hintText: 'YYYY',
                  labelStyle: TextStyle(fontSize: accessible ? 18 : 16),
                  errorText: _yearController.text.isNotEmpty && !validYear
                      ? 'Enter a year from 2000 to 2100'
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Text('Month', style: TextStyle(fontSize: accessible ? 19 : 16)),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
                children: [
                  for (var month = 1; month <= 12; month++)
                    Semantics(
                      button: true,
                      selected: _selectedMonth == month,
                      label: 'Month $month',
                      child: Material(
                        color: _selectedMonth == month
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surface,
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: _selectedMonth == month
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        child: InkWell(
                          onTap: () => setState(() => _selectedMonth = month),
                          customBorder: const StadiumBorder(),
                          child: Center(
                            child: Text(
                              month.toString().padLeft(2, '0'),
                              style: TextStyle(
                                fontSize: accessible ? 19 : 16,
                                fontWeight: FontWeight.w700,
                                color: _selectedMonth == month
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: validYear
              ? () => Navigator.pop(
                  context,
                  DateTime(year, _selectedMonth + 1, 0, 23, 59, 59),
                )
              : null,
          child: const Text('Use date'),
        ),
      ],
    );
  }
}
