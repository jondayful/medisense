import 'package:flutter/widgets.dart';

/// Android's remove-animations and iOS's Reduce Motion use separate flags.
bool prefersReducedMotion(BuildContext context) =>
    MediaQuery.of(context).disableAnimations ||
    WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .reduceMotion;
