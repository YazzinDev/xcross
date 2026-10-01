@pragma('vm:never-inline')
int sumSquares(int n) => Iterable<int>.generate(
  n,
  (i) => i + 1,
).fold(0, (sum, value) => sum + value * value);

void main(List<String> arguments) {
  final n = arguments.isEmpty ? 100 : int.parse(arguments.single);
  print(
    'release=${const bool.fromEnvironment('dart.vm.product')} ${sumSquares(n)}',
  );
}
