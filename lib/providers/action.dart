import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/boot_guard.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/actions/system_exit.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:yaml/yaml.dart';
import 'package:url_launcher/url_launcher.dart';

part 'actions/common.dart';
part 'actions/setup.dart';
part 'actions/backup.dart';
part 'actions/core.dart';
part 'actions/system.dart';
part 'actions/store.dart';
part 'actions/theme.dart';
part 'actions/proxies.dart';
part 'actions/profiles.dart';
part 'actions/geo_resource.dart';
part 'actions/updating.dart';
part 'generated/action.g.dart';

/// Latest per-resource preparation event shown on the Profiles page.
/// A manual provider keeps this transient UI state independent of generated
/// action providers and is cleared by every operation in a finally block.
class RulePreparationProgressNotifier
    extends Notifier<Map<String, RulePreparationProgress>> {
  @override
  Map<String, RulePreparationProgress> build() => const {};

  void update(RulePreparationProgress progress) {
    state = {...state, progress.key: progress};
  }

  void clear({String? key, int? profileId}) {
    if (key == null && profileId == null) {
      state = {};
      return;
    }
    final next = {...state};
    if (key != null) next.remove(key);
    if (profileId != null) {
      next.removeWhere((entryKey, value) => value.profileId == profileId);
    }
    state = next;
  }
}

final rulePreparationProgressProvider =
    NotifierProvider<
      RulePreparationProgressNotifier,
      Map<String, RulePreparationProgress>
    >(RulePreparationProgressNotifier.new);
