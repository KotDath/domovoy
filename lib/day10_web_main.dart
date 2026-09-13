import 'package:flutter/widgets.dart';

import 'day10_main.dart';
import 'demos/demo_dependencies.dart';

Object? webSemanticsHandle;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  webSemanticsHandle = WidgetsBinding.instance.ensureSemantics();
  runApp(
    Day10DemoApp(dependencies: DemoDependencies.diagnostic(browserRelay: true)),
  );
}
