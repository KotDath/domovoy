import 'package:flutter/widgets.dart';

import 'day09_main.dart';
import 'demos/day09_dependencies.dart';

Object? webSemanticsHandle;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  webSemanticsHandle = WidgetsBinding.instance.ensureSemantics();
  runApp(
    Day09DemoApp(
      dependencies: Day09DemoDependencies.production(browserRelay: true),
    ),
  );
}
