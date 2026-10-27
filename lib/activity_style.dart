import 'package:flutter/material.dart';

/// How an activity (Android activity recognition) is shown: route colour,
/// icon and name.
class ActivityStyle {
  const ActivityStyle(this.color, this.emoji, this.name);

  final Color color;
  final String emoji;
  final String name;
}

const kActivityStyles = <String, ActivityStyle>{
  'IN_VEHICLE': ActivityStyle(Color(0xFF2F6FED), '🚗', 'In vehicle'),
  'ON_BICYCLE': ActivityStyle(Color(0xFF00B8D9), '🚲', 'On bicycle'),
  'WALKING': ActivityStyle(Color(0xFF30A46C), '🚶', 'Walking'),
  'ON_FOOT': ActivityStyle(Color(0xFF46A758), '🚶', 'On foot'),
  'RUNNING': ActivityStyle(Color(0xFF8E4EC6), '🏃', 'Running'),
  'STILL': ActivityStyle(Color(0xFF8B8D98), '🧍', 'Still'),
  'TILTING': ActivityStyle(Color(0xFF8B8D98), '📱', 'Tilting'),
  'UNKNOWN': ActivityStyle(Color(0xFF7C8DB5), '❔', 'Unknown'),
};

ActivityStyle activityStyle(String? activity) =>
    kActivityStyles[activity] ?? kActivityStyles['UNKNOWN']!;
