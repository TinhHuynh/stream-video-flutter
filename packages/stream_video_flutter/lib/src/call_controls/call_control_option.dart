import 'package:flutter/material.dart';

import '../../stream_video_flutter.dart';

/// Widget that represents a call control option.
class CallControlOption extends StatelessWidget {
  /// Creates a new instance of [CallControlOption].
  const CallControlOption({
    super.key,
    required this.icon,
    this.iconColor,
    this.elevation,
    this.backgroundColor,
    this.shape,
    this.padding,
    this.onPressed,
  });

  /// The icon of the call control option.
  final Widget icon;

  /// The color of the icon of the call control option.
  final Color? iconColor;

  /// The elevation of the call control option.
  final double? elevation;

  /// The background color of the call control option.
  final Color? backgroundColor;

  /// The shape of the call control option.
  final OutlinedBorder? shape;

  /// The padding applied to the call control option.
  final EdgeInsetsGeometry? padding;

  /// The callback to invoke when the user taps on the call control option.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = StreamVideoTheme.of(context);
    final barTheme = theme.callControlsBarTheme;

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        elevation: elevation ?? barTheme.optionElevation,
        backgroundColor: backgroundColor ?? barTheme.optionBackgroundColor,
        shape: shape ?? barTheme.optionShape,
        padding: padding ?? barTheme.optionPadding,
      ),
      onPressed: onPressed,
      child: IconTheme.merge(
        data: IconThemeData(color: iconColor ?? barTheme.optionIconColor),
        child: icon,
      ),
    );
  }
}
