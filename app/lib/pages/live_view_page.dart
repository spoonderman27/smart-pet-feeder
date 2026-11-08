import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/feeder_models.dart';
import '../services/feeder_service.dart';
import '../widgets/common.dart';

/// Shows what the feeder camera sees, about one picture per second.
///
/// The Pi only uploads pictures while this page asks for them, and the page
/// pauses itself after one minute, so mobile data is not wasted.
class LiveViewPage extends StatefulWidget {
  const LiveViewPage({super.key});

  @override
  State<LiveViewPage> createState() => _LiveViewPageState();
}

class _LiveViewPageState extends State<LiveViewPage> {
  static const _session = Duration(seconds: 60);
  static const _requestSeconds = 30; // renewed every 15 s while watching

  final _feeder = FeederService.instance;
  late final Stream<LiveFrame> _live = _feeder.liveStream();
  late final Stream<FeederConfig> _config = _feeder.configStream();

  Timer? _keepAlive;
  Timer? _ticker;
  DateTime _endsAt = DateTime.now();
  bool _watching = false;

  String? _decodedFrom;
  Uint8List? _image;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    _ticker?.cancel();
    if (_watching) _send(0);
    super.dispose();
  }

  void _send(int seconds) {
    unawaited(_feeder.requestLive(seconds: seconds).catchError((Object _) {}));
  }

  void _start() {
    _endsAt = DateTime.now().add(_session);
    _watching = true;
    _send(_requestSeconds);
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_watching && DateTime.now().isBefore(_endsAt)) _send(_requestSeconds);
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_watching && DateTime.now().isAfter(_endsAt)) {
        _stop();
      } else {
        setState(() {});
      }
    });
    if (mounted) setState(() {});
  }

  void _stop() {
    _keepAlive?.cancel();
    _watching = false;
    _send(0);
    if (mounted) setState(() {});
  }

  Uint8List? _decode(String? b64) {
    if (b64 == null || b64.isEmpty) return _image;
    if (b64 != _decodedFrom) {
      try {
        _image = base64Decode(b64);
        _decodedFrom = b64;
      } catch (_) {/* keep the previous picture */}
    }
    return _image;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live view')),
      // Both streams stay subscribed for the whole page. (Switching between
      // the "camera off" view and the picture must not listen to a stream
      // twice - that caused "Bad state: Stream has already been listened to".)
      body: StreamBuilder<FeederConfig>(
        stream: _config,
        builder: (context, configSnap) {
          final config = configSnap.data ?? FeederConfig.defaults;
          return StreamBuilder<LiveFrame>(
            stream: _live,
            builder: (context, snap) => config.cameraMode == 'off'
                ? _cameraOff()
                : _body(snap.data ?? const LiveFrame(), config),
          );
        },
      ),
    );
  }

  Widget _cameraOff() {
    return Center(
      child: EmptyState(
        icon: Icons.videocam_off_outlined,
        title: 'The camera is switched off',
        message: 'Turn it to Auto or On to see the live view. '
            'In Off mode the feeder does not feed pets automatically.',
        action: FilledButton.icon(
          onPressed: () async {
            final ok = await runWithFeedback(
              context,
              () => _feeder.setCameraMode('auto'),
              success: 'Camera set to AUTO',
            );
            if (ok) _start();
          },
          icon: const Icon(Icons.auto_mode),
          label: const Text('Turn camera to Auto'),
        ),
      ),
    );
  }

  Widget _body(LiveFrame frame, FeederConfig config) {
    final theme = Theme.of(context);
    final image = frame.isFresh ? _decode(frame.imageBase64) : null;
    final left = _endsAt.difference(DateTime.now()).inSeconds.clamp(0, 999);

    Widget picture;
    if (image != null && _watching) {
      picture = Image.memory(image, fit: BoxFit.contain, gaplessPlayback: true);
    } else if (_watching) {
      picture = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 12),
            Text('Waking up the camera...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    } else {
      picture = Stack(
        fit: StackFit.expand,
        children: [
          if (_image != null)
            Opacity(opacity: 0.35, child: Image.memory(_image!, fit: BoxFit.contain)),
          const Center(
            child: Text('Live view paused to save data',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: PageBody(
        maxWidth: 720,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Container(color: Colors.black, child: picture),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 12,
                    color: image != null && _watching ? Colors.red : Colors.grey),
                const SizedBox(width: 6),
                Text(image != null && _watching ? 'LIVE' : 'Not live',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    frame.time == null ? '' : 'Picture from ${timeAgo(frame.time)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (_watching)
                  Text('Pauses in $left s', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 12),
            if (_watching)
              OutlinedButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
              )
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Keep watching (1 more minute)'),
              ),
          ],
        ),
      ),
    );
  }
}
