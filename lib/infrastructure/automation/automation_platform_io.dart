import 'dart:io';

bool automationPausesInBackground() => Platform.isAndroid || Platform.isIOS;
