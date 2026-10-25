import 'package:flutter/material.dart';

/// A screen that also lives inside another screen (Files shows Library, Sites and Trash as filters).
/// Standalone it gets its own Scaffold and app bar; embedded it is just the body.
Widget maybeScaffold({required bool embedded, PreferredSizeWidget? appBar, required Widget body}) =>
    embedded ? body : Scaffold(appBar: appBar, body: body);
