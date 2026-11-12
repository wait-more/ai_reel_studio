import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pipeline_bridge.dart';
import 'pipeline_engine.dart';
import 'pipeline_models.dart';
import 'pipeline_store.dart';

/// 应用级流水线服务：启停 HTTP 桥、刷新 Job 列表。
class PipelineService {
  PipelineService._();
  static final PipelineService instance = PipelineService._();

  bool _started = false;

  Future<void> ensureStarted({bool rewriteBridgeInfo = false}) async {
    try {
      if (_started && PipelineBridge.instance.isRunning) {
        if (rewriteBridgeInfo) {
          final b = PipelineBridge.instance;
          if (b.port != null && b.baseUrl != null) {
            await PipelineStore.instance.writeBridgeInfo(
              port: b.port!,
              baseUrl: b.baseUrl!,
            );
          }
        }
        return;
      }
      await PipelineBridge.instance.start();
      _started = true;
    } catch (_) {
      _started = false;
      rethrow;
    }
  }

  Future<void> stop() async {
    await PipelineBridge.instance.stop();
    _started = false;
  }
}

/// 仅驱动 Job 列表 / 详情刷新；不要拿它刷配置页。
final pipelineJobsTickProvider = StateProvider<int>((ref) => 0);

/// 仅在显式保存/重载配置时递增。
final pipelineConfigTickProvider = StateProvider<int>((ref) => 0);

final pipelineJobsProvider =
    FutureProvider.autoDispose<List<PipelineJob>>((ref) async {
  ref.watch(pipelineJobsTickProvider);
  return PipelineStore.instance.listJobs();
});

final pipelineConfigProvider =
    FutureProvider.autoDispose<PipelineConfig>((ref) async {
  ref.watch(pipelineConfigTickProvider);
  return PipelineStore.instance.loadConfig();
});

final pipelineBridgeInfoProvider = Provider<String>((ref) {
  // 桥地址几乎不变；跟 config tick 走即可，避免 Job 轮询带动顶栏闪烁。
  ref.watch(pipelineConfigTickProvider);
  final b = PipelineBridge.instance;
  if (!b.isRunning || b.baseUrl == null) return '未启动';
  return b.baseUrl!;
});

void bumpPipelineJobsTick(WidgetRef ref) {
  ref.read(pipelineJobsTickProvider.notifier).state++;
}

void bumpPipelineConfigTick(WidgetRef ref) {
  ref.read(pipelineConfigTickProvider.notifier).state++;
}

/// 兼容旧调用：只刷 Job，不刷配置。
void bumpPipelineTick(WidgetRef ref) => bumpPipelineJobsTick(ref);

/// Engine 变更只刷新 Job 侧；节流加长，避免生成中狂刷导致界面假死。
void bindPipelineEngineToProviders(ProviderContainer container) {
  Timer? debounce;
  void onChange() {
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), () {
      container.read(pipelineJobsTickProvider.notifier).state++;
    });
  }

  PipelineEngine.instance.addListener(onChange);
}
