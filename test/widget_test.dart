import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanpro_studio/core/units.dart';
import 'package:scanpro_studio/features/passport/print_layout.dart';
import 'package:scanpro_studio/features/passport/sheet_preview.dart';
import 'package:scanpro_studio/shared/theme.dart';
import 'package:scanpro_studio/shared/widgets.dart';

void main() {
  testWidgets('EmptyState renders title, message and action', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: EmptyState(icon: Icons.inbox, title: 'Nothing', message: 'Add something', action: FilledButton(onPressed: () {}, child: const Text('Add'))),
      ),
    ));
    expect(find.text('Nothing'), findsOneWidget);
    expect(find.text('Add something'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
  });

  testWidgets('Sheet preview draws one cell per placed photo', (tester) async {
    const spec = SheetSpec(paper: PaperSizes.a4, photoWmm: 35, photoHmm: 45, copies: 6);
    final layout = PrintLayoutEngine.compute(spec);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SizedBox(width: 400, height: 600, child: SheetPreview(layout: layout, spec: spec))),
    ));
    expect(find.byType(Positioned), findsNWidgets(layout.placed + 1));
  });

  testWidgets('LabeledSlider reports changes', (tester) async {
    double v = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (ctx, set) => LabeledSlider(label: 'Contrast', value: v, onChanged: (x) => set(() => v = x))),
      ),
    ));
    await tester.drag(find.byType(Slider), const Offset(100, 0));
    expect(v, isNot(0));
  });
}
