import 'dart:ffi';
import 'package:meta/meta.dart';

final class ProbePair extends Struct {
  @Int64()
  external int integer;
  @Double()
  external double fraction;
}

@Native<ProbePair Function(Int64, Double)>(symbol: 'probe_pair')
external ProbePair makePair(int integer, double fraction);

@Native<Double Function(ProbePair)>(symbol: 'probe_sum_pair')
external double sumPair(ProbePair value);

@Native<Int64 Function(Int64, Pointer<NativeFunction<Int64 Function(Int64)>>)>(
  symbol: 'probe_callback',
)
external int callCallback(
  int value,
  Pointer<NativeFunction<Int64 Function(Int64)>> callback,
);

@Native<Int64 Function()>(symbol: 'probe_product')
external int productBuild();

@RecordUse()
String recordedMarker(String value) => value;
