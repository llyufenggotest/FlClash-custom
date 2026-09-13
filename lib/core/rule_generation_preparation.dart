enum RulePreparationPhase {
  queued,
  downloading,
  cacheHit,
  validating,
  compiling,
  commit,
  complete,
  error,
}

class RulePreparationProgress {
  final int profileId;
  final String operationId;
  final RulePreparationPhase phase;
  final String kind;
  final String name;
  final String path;
  final Object? error;

  const RulePreparationProgress({
    this.profileId = 0,
    this.operationId = '',
    required this.phase,
    required this.kind,
    required this.name,
    required this.path,
    this.error,
  });

  String get key => '$profileId:$operationId';
}

class RuleGenerationPreparation {
  final String fingerprint;
  final String config;
  final String generation;
  final String configPath;

  const RuleGenerationPreparation({
    required this.fingerprint,
    required this.config,
    required this.generation,
    required this.configPath,
  });
}
