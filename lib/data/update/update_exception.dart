import 'dart:io';

import 'package:dio/dio.dart';
import 'package:herdr_pocket/data/update/update_failure.dart';

/// A failure that has been classified into [UpdateFailure].
///
/// Thrown by the client and the downloader, caught by the controller, and never
/// caught anywhere else: the whole point of carrying the tag is that no caller
/// has to read a message to decide what to say to the user.
class UpdateException implements Exception {
  /// Holds one classified failure.
  const UpdateException(this.failure, {this.detail});

  /// What went wrong, in this app's vocabulary.
  final UpdateFailure failure;

  /// The raw message, kept for diagnostics. Never shown as the whole sentence.
  final String? detail;

  @override
  String toString() =>
      'UpdateException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Turns a dio failure into this app's vocabulary.
///
/// [proxied] is the one piece of context dio cannot supply and the caller can:
/// whether a proxy was in force for this request. Without it, "the connection
/// was refused" is a sentence about the phone, and with it, it is a sentence
/// about the proxy app on port 7890 — which is the one the user can act on.
UpdateException classifyDio(DioException error, {required bool proxied}) {
  final failure = switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout =>
      UpdateFailure.timedOut,
    DioExceptionType.badCertificate => UpdateFailure.tlsRejected,
    DioExceptionType.cancel => UpdateFailure.cancelled,
    DioExceptionType.badResponse => _classifyStatus(error.response?.statusCode),
    DioExceptionType.connectionError =>
      _classifyTransport(error.error, proxied: proxied),
    DioExceptionType.unknown =>
      _classifyTransport(error.error, proxied: proxied),
  };
  return UpdateException(
    failure,
    detail: '${error.type.name}${error.message == null ? '' : ': ${error.message}'}'
        '${error.response == null ? '' : ' (HTTP ${error.response?.statusCode})'}',
  );
}

/// A 403 from GitHub's REST API is the anonymous rate limit far more often than
/// it is a real permission problem — this repository is public, so there is
/// nothing to be forbidden from.
UpdateFailure _classifyStatus(int? status) => switch (status) {
      403 || 429 => UpdateFailure.rateLimited,
      404 => UpdateFailure.noRelease,
      _ => UpdateFailure.httpStatus,
    };

/// Reads the underlying error, which is where TLS and DNS actually live.
///
/// `DioExceptionType.connectionError` covers "a SocketException happened" and
/// `unknown` covers "some other Error", so the useful information is in
/// [DioException.error] rather than in the type. This is the one place that
/// knows that, and after it nothing has to.
UpdateFailure _classifyTransport(Object? error, {required bool proxied}) {
  if (error is HandshakeException) return UpdateFailure.tlsRejected;
  // A JSON content type over a body that is not JSON: a captive portal or a
  // proxy's error page, and worth saying so rather than "unknown".
  if (error is FormatException) return UpdateFailure.badPayload;
  if (error is SocketException || error is HttpException) {
    return proxied ? UpdateFailure.proxyRefused : UpdateFailure.offline;
  }
  return UpdateFailure.unknown;
}
