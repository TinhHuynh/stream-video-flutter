import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:stream_video/protobuf/google/protobuf/struct.pb.dart';
import 'package:stream_video/protobuf/video/coordinator/client_v1_rpc/client_rpc.pb.dart';
import 'package:stream_video/protobuf/video/coordinator/client_v1_rpc/client_rpc.pbtwirp.dart';
import 'package:stream_video/protobuf/video/coordinator/edge_v1/edge.pb.dart'
    hide EdgeServer;
import 'package:stream_video/protobuf/video/coordinator/event_v1/event.pb.dart';
import 'package:stream_video/src/core/error/error.dart';

import 'package:stream_video/src/core/http/token_manager.dart';
import 'package:stream_video/src/latency_service/latency.dart';
import 'package:stream_video/src/models/edge_server.dart';
import 'package:stream_video/src/models/video_options.dart';
import 'package:stream_video/src/sfu-client/rpc/signal.dart';
import 'package:stream_video/src/sfu-client/rtc/client.dart';
import 'package:stream_video/src/state/state.dart';
import 'package:stream_video/src/ws/websocket.dart';
import 'package:stream_video/stream_video.dart';
import 'package:tart/tart.dart';

/// Handler function used for logging records. Function requires a single
/// [LogRecord] as the only parameter.
typedef LogHandlerFunction = void Function(LogRecord record);

final _levelEmojiMapper = {
  Level.INFO: 'ℹ️',
  Level.WARNING: '⚠️',
  Level.SEVERE: '🚨',
};

class StreamVideoClientOptions {
  StreamVideoClientOptions({this.retries = 3});
  final int retries;
}

class StreamVideoClient {
  // late final StreamSubscription<StatsEvent>? statsListener;
  final String apiKey;
  StreamVideoClient(
    this.apiKey, {
    this.logLevel = Level.INFO,
    String? coordinatorUrl,
    String? baseURL,
    StreamVideoClientOptions? options,
    this.logHandlerFunction = StreamVideoClient.defaultLogHandler,
    WebSocketClient? ws,
  }) {
    _callCoordinatorService = ClientRPCProtobufClient(
      // Change it to your local IP address.
      coordinatorUrl ??
          "http://05a8-2a01-cb20-87c-f00-710c-711a-2bbb-ef5.ngrok.io/rpc", //https://rpc-video-coordinator.oregon-v1.stream-io-video.com
      "",
      hooks: ClientHooks(
        onRequestPrepared: onClientRequestPrepared,
      ),
      // interceptor: myInterceptor()
    );

    _state = ClientState(logger);
    _options = options ?? StreamVideoClientOptions();
    _rtcClient = WebRTCClient(
      SignalService(_tokenManager,
          endpoint:
              "http://192.168.1.17:3031/rpc"), //https://sfu2.fra1.gtstrm.com/twirp
      state: _state,
      logger: logger,
    );
    _ws = ws ??
        WebSocketClient(
            logger: logger,
            state: _state,
            apiKey: apiKey,
            endpoint:
                // Change it to your local IP address.
                'ws://192.168.1.17:8989/rpc/stream.video.coordinator.client_v1_rpc.Websocket/Connect'); // 'ws://wss-video-coordinator.oregon-v1.stream-io-video.com/rpc/stream.video.coordinator.client_v1_rpc.Websocket/Connect');

    _latencyService = LatencyService(logger: logger);
  }
  late final ClientRPCProtobufClient _callCoordinatorService;
  late final LatencyService _latencyService;
  late final WebSocketClient _ws;
  late final WebRTCClient _rtcClient;
  final _tokenManager = TokenManager();

  /// Client specific logger instance.
  /// Refer to the class [Logger] to learn more about the specific
  /// implementation.
  late final Logger logger = detachedLogger('📡');

  /// This client state
  late final ClientState _state;

  ///options
  late final StreamVideoClientOptions _options;
  final LogHandlerFunction logHandlerFunction;

  final Level logLevel;

  /// Default log handler function for the [StreamChatClient] logger.
  static void defaultLogHandler(LogRecord record) {
    print(
      '${record.time} '
      '${_levelEmojiMapper[record.level] ?? record.level.name} '
      '${record.loggerName} ${record.message} ',
    );
    if (record.error != null) print(record.error);
    if (record.stackTrace != null) print(record.stackTrace);
  }

  /// Default logger for the [StreamChatClient].
  Logger detachedLogger(String name) => Logger.detached(name)
    ..level = logLevel
    ..onRecord.listen(logHandlerFunction);

  UserInfo? get currentUser => _state.currentUser;

  CallParticipantController get room => _state.participants;

  Future<void> setUser(
    UserInfo user, {
    Token? token,
    TokenProvider? provider,
    bool connectWebSocket = true,
  }) async {
    logger
      ..info('setting user : ${user.id}')
      ..info('setting token : ${token!.rawValue}');

    await _tokenManager.setTokenOrProvider(
      user.id,
      token: token,
      provider: provider,
    );

    _state.currentUser = user;
  }

  CallController get calls => _state.calls;

  void fakeIncomingCall(String createdByUserId) {
    logger.info('faking call from $createdByUserId');
    // _state.calls.emitCreated(CallCreated(callCid: [createdByUserId]));
  }

  Future<void> connectWs() async {
    final user = _state.currentUser;

    final token = await _tokenManager.loadToken();
    logger.info('connect user $user with token ${token.rawValue}');
    _ws.connect(user: user!, token: token);
  }

  Future<EdgeServer> selectEdgeServer({
    required String callId,
    required Map<String, Latency> latencyByEdge,
  }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _withAuth(token);

      final response = await _callCoordinatorService.getCallEdgeServer(
        ctx,
        GetCallEdgeServerRequest(
          callCid: callId,
          measurements: LatencyMeasurements(
            measurements: latencyByEdge,
          ),
        ),
      );
      return EdgeServer(
        token: response.credentials.token,
        url: response.credentials.server.url,
      );
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
        'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}',
      );
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }

  Future<void> disableAudio() async {
    await _rtcClient.disableAudio();
  }

  Future<void> enableAudio() async {
    await _rtcClient.disableAudio();
  }

  Future<void> enableVideo() async {
    await _rtcClient.disableAudio();
  }

  Future<void> disableVideo() async {
    await _rtcClient.disableVideo();
  }

  Future<void> joinExistingCall({
    required String callId,
    required StreamCallType callType,
    VideoOptions videoOptions = const VideoOptions(
      adaptiveStream: true,
      dynacast: true,
      autoSubscribe: true,
      simulcast: true,
      // videoPresets: VideoParametersPresets.screenShareH720FPS15,
      reportStats: true,
    ),
    //TODO: expose more parameters
  }) async {
    final edges = await joinCall(callId: callId, callType: callType);
    final latencyByEdge =
        await _latencyService.measureLatencies(edges, _options.retries);
    final edgeServer =
        await selectEdgeServer(callId: callId, latencyByEdge: latencyByEdge);

    final callState = await _rtcClient.connect(
      callId: callId,
      callType: callType,
      sfuUrl: edgeServer.url,
      sfuToken: edgeServer.token,
      options: videoOptions,
    );
  }

  Future<void> startCall({
    required String id,
    required List<String> participantIds,
    required StreamCallType callType,
    VideoOptions videoOptions = const VideoOptions(
      adaptiveStream: true,
      dynacast: true,
      autoSubscribe: true,
      simulcast: true,
      // videoPresets: VideoParametersPresets.screenShareH720FPS15,
      reportStats: true,
    ),
    //TODO: expose more parameters
  }) async {
    final createCallResponse = await createCall(
      callId: id,
      participantIds: participantIds,
      callType: callType,
    );

    final callId = createCallResponse.call.call.callCid;
    logger
        .info("created call with id $callId and participants $participantIds");

    final edges = await joinCall(callId: callId, callType: callType);
    final latencyByEdge =
        await _latencyService.measureLatencies(edges, _options.retries);
    final edgeServer =
        await selectEdgeServer(callId: callId, latencyByEdge: latencyByEdge);

    final callState = await _rtcClient.connect(
      callId: callId,
      callType: callType,
      sfuUrl: edgeServer.url,
      sfuToken: edgeServer.token,
      options: videoOptions,
    );
  }

  Future<CreateCallResponse> createCall({
    required String callId,
    required List<String> participantIds,
    required StreamCallType callType,
    //TODO: expose more parameters
  }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _withAuth(token);
      const jsonEncoder = JsonEncoder();
      final members = {
        for (var participantId in participantIds)
          participantId: MemberInput(
            role: "admin",
            customJson: utf8.encode(
              jsonEncoder.convert({}),
            ),
          ),
      };

      final response = await _callCoordinatorService.createCall(
        ctx,
        CreateCallRequest(
          id: callId,
          input: CreateCallInput(
            // call:CallInput(
            //   options: CallOptions()
            // ),
            members: members,
          ),
          type: callType.rawType,
        ),
      );
      return response;
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
        'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}',
      );
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }

  Context _withAuth(Token token) {
    return withHttpRequestHeaders(
      Context(),
      {'authorization': 'Bearer ${token.rawValue}', 'api_key': apiKey},
    );
  }

  Future<List<Edge>> joinCall({
    required String callId,
    required StreamCallType callType,
  }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _withAuth(token);

      final response = await _callCoordinatorService.joinCall(
        ctx,
        JoinCallRequest(
          id: callId,
          type: callType.rawType,
          // input: CreateCallInput(call: CallInput(options: CallOptions())),
          // datacenterId: 'milan',
        ),
      );
      return response.edges;
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
        'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}',
      );
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }

  Future<void> reportCallStats({
    required StreamCallType callType,
    required String callId,
    required List<int> stats,
  }) async {
    try {
      final token = await _tokenManager.loadToken();
      final ctx = _withAuth(token);

      await _callCoordinatorService.reportCallStats(
        ctx,
        ReportCallStatsRequest(
          callId: callId,
          callType: callType.rawType,
          statsJson: stats,
        ),
      );
    } on TwirpError catch (e) {
      final method =
          e.getContext.value(ContextKeys.methodName) ?? 'unknown method';
      throw StreamVideoError(
        'Twirp error on method: $method. Code: ${e.getCode}. Message: ${e.getMsg}',
      );
    } on InvalidTwirpHeader catch (e) {
      throw StreamVideoError('InvalidTwirpHeader: $e');
    } catch (e, stack) {
      throw StreamVideoError('''
      Unknown Exception Occurred: $e
      Stack trace: $stack
      ''');
    }
  }
}

/// onClientRequestPrepared is a client hook used to print out the method name of the RPC call
Context onClientRequestPrepared(Context ctx, Request req) {
  final methodNameVal = ctx.value(ContextKeys.methodName);
  print('RequestPrepared for $methodNameVal');
  return ctx;
}

/// myInterceptor is an example of how to use an interceptor to catch the context and request
/// before the RPC is made to the server. Depending on how many interceptors there are [next]
/// could represent another interceptor by using [chainInterceptor] or the actual RPC call
// Interceptor myInterceptor(/* pass in any dependencies needed */) {
//   return (Method next) {
//     return (Context ctx, dynamic req) {
//       switch (req.runtimeType) {
//         case Size:
//           print('This will be ran before the makeHat call');
//           break;
//         case SuitSizeReq:
//           print('This will be ran before the makeSuit call');
//       }
//       final serviceName = ctx.value(ContextKeys.serviceName);
//       final methodName = ctx.value(ContextKeys.methodName);
//       final reqDetails = req.toString().replaceAll('\n', '');
//       print('Service: $serviceName, Method: $methodName, Request: $reqDetails');

//       // ALWAYS call the next method (interceptor or RPC call)
//       return next(ctx, req);
//     };
//   };
// }
