/// Captures exactly one value from a chunked converter without depending on
/// package:convert as a direct application dependency.
final class SingleValueSink<T> implements Sink<T> {
  T? _value;
  bool _hasValue = false;

  T get value {
    if (!_hasValue) throw StateError('chunked conversion produced no value');
    return _value as T;
  }

  @override
  void add(T data) {
    if (_hasValue) throw StateError('chunked conversion produced multiple values');
    _value = data;
    _hasValue = true;
  }

  @override
  void close() {}
}
