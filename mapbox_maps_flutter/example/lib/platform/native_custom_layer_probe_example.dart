// The cube probe is experimental and deliberately separate from glTF support.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

/// Manual P0B harness. Its fixed coordinate is test data, never device GPS.
class NativeCustomLayerProbeExample extends StatefulWidget {
  const NativeCustomLayerProbeExample({super.key});

  @override
  State<NativeCustomLayerProbeExample> createState() =>
      _NativeCustomLayerProbeExampleState();
}

class _NativeCustomLayerProbeExampleState
    extends State<NativeCustomLayerProbeExample> {
  static const _latitude = 10.7769;
  static const _longitude = 106.7009;
  MapboxMap? _map;
  bool _ready = false;
  bool _busy = false;
  bool _paused = false;
  bool _dark = true;
  String _status = 'Cube probe only. Skeletal animation is not implemented.';

  Future<void> _run(Future<void> Function(MapboxMap map) operation) async {
    final map = _map;
    if (map == null || !_ready || _busy) return;
    setState(() => _busy = true);
    try {
      await operation(map);
    } catch (error) {
      if (!mounted) return;
      final label = error is PlatformException
          ? error.code
          : error.runtimeType.toString();
      setState(() => _status = 'Probe failed: $label');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh(MapboxMap map) async {
    final diagnostics = await map.nativeCustomLayerProbe.getDiagnostics();
    if (!mounted) return;
    final incomingWarning = diagnostics.incomingGlErrorCode;
    setState(() {
      _paused = diagnostics.paused;
      _status =
          '${diagnostics.backend.name}: '
          'layer=${diagnostics.styleLayerPresent}, '
          'GPU initialized=${diagnostics.initialized}, '
          'draws submitted=${diagnostics.renderedFrames}, '
          'repaint=${diagnostics.repaintEnabled}, '
          'error=${diagnostics.lastErrorCode ?? 'none'}. '
          '${incomingWarning == null ? '' : 'Incoming GL warning: $incomingWarning. '}'
          'Verify the actual map output; this is not a benchmark.';
    });
  }

  Future<void> _attach(MapboxMap map) async {
    await map.nativeCustomLayerProbe.attachCube(
      NativeCubeProbeOptions(latitude: _latitude, longitude: _longitude),
    );
    await _refresh(map);
  }

  Future<void> _togglePause(MapboxMap map) async {
    await map.nativeCustomLayerProbe.setPaused(!_paused);
    await _refresh(map);
  }

  Future<void> _detach(MapboxMap map) async {
    await map.nativeCustomLayerProbe.detach();
    await _refresh(map);
  }

  Future<void> _reloadStyle(MapboxMap map) async {
    final dark = !_dark;
    await map.loadStyleURI(dark ? MapboxStyles.DARK : MapboxStyles.LIGHT);
    if (mounted) setState(() => _dark = dark);
  }

  @override
  void dispose() {
    // The SDK's MapWidget owns map disposal and the native host cleanup.
    _map = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _ready && !_busy;
    return Stack(
      children: [
        MapWidget(
          styleUri: MapboxStyles.DARK,
          viewport: CameraViewportState(
            center: Point(coordinates: Position(_longitude, _latitude)),
            zoom: 17,
            pitch: 55,
          ),
          onMapCreated: (map) => _map = map,
          onMapIdleListener: (_) {
            if (!_ready && mounted) setState(() => _ready = true);
          },
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_status),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: enabled ? () => _run(_attach) : null,
                          child: const Text('Attach cube'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_togglePause) : null,
                          child: Text(_paused ? 'Resume' : 'Pause'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_reloadStyle) : null,
                          child: const Text('Reload style'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_refresh) : null,
                          child: const Text('Read diagnostics'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_detach) : null,
                          child: const Text('Detach'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
