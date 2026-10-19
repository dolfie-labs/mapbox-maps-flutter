// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

/// One free rigged fixture on the native map. The asset's only clip is unnamed.
class NativeRiggedModelProbeExample extends StatefulWidget {
  const NativeRiggedModelProbeExample({super.key});
  @override
  State<NativeRiggedModelProbeExample> createState() =>
      _RiggedModelExampleState();
}

class _RiggedModelExampleState extends State<NativeRiggedModelProbeExample> {
  MapboxMap? _map;
  bool _ready = false;
  bool _busy = false;
  bool _paused = false;
  bool _dark = true;
  String _status = 'One model; native skeletal animation; clip 0 has no name.';

  Future<void> _run(Future<void> Function(MapboxMap) operation) async {
    final map = _map;
    if (map == null || !_ready || _busy) return;
    setState(() => _busy = true);
    try {
      await operation(map);
    } catch (error) {
      if (!mounted) return;
      final code = error is PlatformException
          ? error.code
          : error.runtimeType.toString();
      setState(() => _status = 'Rigged probe failed: $code');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh(MapboxMap map) async {
    final state = await map.nativeRiggedModelProbe.getDiagnostics();
    if (!mounted) return;
    setState(() {
      _paused = state.paused;
      _status =
          '${state.backend.name}: requested=${state.requested}, '
          'GPU ready=${state.ready}, draws=${state.renderedFrames}, '
          'pose=${state.poseRevision}, time=${state.animationTimeSeconds.toStringAsFixed(3)}s, '
          'vertices=${state.vertexCount}, joints=${state.jointCount}, '
          'clips=${state.clipCount}, clip index=${state.clipIndex}, '
          'error=${state.lastErrorCode ?? 'none'}'
          '${state.incomingGlErrorCode == null ? '' : ', incoming GL warning=${state.incomingGlErrorCode}'}';
    });
  }

  Future<void> _attach(MapboxMap map) async {
    final data = await rootBundle.load(
      'assets/animated_entities/RiggedSimple.glb',
    );
    if (!mounted) return;
    await map.nativeRiggedModelProbe.attachRiggedModel(
      NativeRiggedModelProbeOptions(
        glbBytes: data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ),
        latitude: 10.7769,
        longitude: 106.7009,
        heightMeters: 40,
      ),
    );
    await _refresh(map);
  }

  Future<void> _pause(MapboxMap map) async {
    await map.nativeRiggedModelProbe.setPaused(!_paused);
    await _refresh(map);
  }

  Future<void> _detach(MapboxMap map) async {
    await map.nativeRiggedModelProbe.detach();
    await _refresh(map);
  }

  Future<void> _reload(MapboxMap map) async {
    final dark = !_dark;
    await map.loadStyleURI(dark ? MapboxStyles.DARK : MapboxStyles.LIGHT);
    if (mounted) setState(() => _dark = dark);
  }

  @override
  void dispose() {
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
            center: Point(coordinates: Position(106.7009, 10.7769)),
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
                    const Text(
                      'Rigged Simple © 2017 Cesium · CC BY 4.0 · clip 0 (unnamed)',
                    ),
                    Text(_status),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: enabled ? () => _run(_attach) : null,
                          child: const Text('Attach rigged model'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_pause) : null,
                          child: Text(_paused ? 'Resume' : 'Pause'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_refresh) : null,
                          child: const Text('Read diagnostics'),
                        ),
                        TextButton(
                          onPressed: enabled ? () => _run(_reload) : null,
                          child: const Text('Reload style'),
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
