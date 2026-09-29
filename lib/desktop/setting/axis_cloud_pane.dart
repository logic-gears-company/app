import 'package:Kelivo/features/settings/pages/axis_cloud_page.dart';
import 'package:flutter/material.dart';

/// Desktop entry for AXIS Cloud. The page itself already resolves to its
/// desktop layout, so the pane just hosts it without a page-level app bar.
class DesktopAxisCloudPane extends StatelessWidget {
  const DesktopAxisCloudPane({super.key});

  @override
  Widget build(BuildContext context) {
    return const AxisCloudPage();
  }
}
