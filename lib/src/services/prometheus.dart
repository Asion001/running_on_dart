import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:nyxx/nyxx.dart';
import 'package:nyxx_commands/nyxx_commands.dart';
import 'package:prometheus_client/prometheus_client.dart';
import 'package:prometheus_client_shelf/shelf_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:prometheus_client_shelf/shelf_metrics.dart' as shelf_metrics;
import 'package:prometheus_client/runtime_metrics.dart' as runtime_metrics;

class PrometheusService {
  static PrometheusService get instance => _instance ?? (throw Exception('PrometheusService must be initialised with PrometheusService.init()'));
  static PrometheusService? _instance;

  static void init(INyxxWebsocket client, CommandsPlugin commands) {
    _instance = PrometheusService._(client, commands);
  }

  final INyxxWebsocket client;
  final CommandsPlugin commands;

  final Logger _logger = Logger('ROD.Metrics');

  PrometheusService._(this.client, this.commands) {
    registerMetrics();
    startHttpServer();
  }

  void registerMetrics() {
    runtime_metrics.register();

    registerPeriodicCollectors();
    registerEventCollectors();
    registerCommandCollectors();
  }

  void registerPeriodicCollectors() {
    Gauge totalUsers = Gauge(name: 'nyxx_total_users_cache', help: "Total number of users in cache")..register();
    Gauge totalChannels = Gauge(name: 'nyxx_total_channels_cache', help: "Total number of channels in cache")..register();
    Gauge messageCacheSize = Gauge(name: 'nyxx_total_messages_cache', help: "Total number of messages in cache")..register();
    Gauge totalVoiceStates = Gauge(name: 'nyxx_total_voice_states_cache', help: "Total number of voice states in cache")..register();
    Gauge shardWebsocketLatency = Gauge(name: 'nyxx_ws_latency', help: "Websocket latency", labelNames: ['shard_id'])..register();

    Timer.periodic(const Duration(seconds: 5), (timer) {
      totalUsers.value = client.users.length.toDouble();
      totalChannels.value = client.channels.length.toDouble();
      messageCacheSize.value = client.channels.values.whereType<ITextChannel>().fold(0, (count, channel) => count + channel.messageCache.length);
      totalVoiceStates.value = client.guilds.values.fold(0, (count, guild) => count + guild.voiceStates.length);

      for (final shard in client.shardManager.shards) {
        shardWebsocketLatency.labels([shard.id.toString()]).value = shard.gatewayLatency.inMilliseconds.toDouble();
      }
    });
  }

  void registerEventCollectors() {
    Counter totalMessagesSent = Counter(name: 'nyxx_total_messages_sent', help: "Total number of messages sent", labelNames: ['guild_id'])..register();
    client.eventsWs.onMessageReceived.listen((event) => totalMessagesSent.labels([event.message.guild?.id.toString() ?? 'dm']).inc());

    Counter totalGuildJoins = Counter(name: 'nyxx_total_guild_joins', help: "Total number of guild joins", labelNames: ['guild_id'])..register();
    client.eventsWs.onGuildMemberAdd.listen((event) => totalGuildJoins.labels([event.guild.id.toString()]).inc());

    Counter httpResponses = Counter(name: 'nyxx_http_response', help: 'Code of http responses', labelNames: ['code'])..register();
    client.eventsRest.onHttpResponse.listen((event) => httpResponses.labels([event.response.statusCode.toString()]).inc());
    client.eventsRest.onHttpError.listen((event) => httpResponses.labels([event.response.statusCode.toString()]).inc());
    client.eventsRest.onRateLimited.listen((event) => httpResponses.labels(['429']).inc());
  }

  void registerCommandCollectors() {
    Counter totalCommands = Counter(name: 'nyxx_total_commands', help: 'The total number of commands used', labelNames: ['name'])..register();
    Counter totalSlashCommands = Counter(name: 'nyxx_total_slash_commands', help: 'The total number of slash commands used', labelNames: ['name'])..register();
    Counter totalTextCommands = Counter(name: 'nyxx_total_text_commands', help: 'The total number of text commands used', labelNames: ['name'])..register();

    commands.onPreCall.listen((context) {
      String name = context.command is ChatCommand ? (context.command as ChatCommand).fullName : context.command.name;

      totalCommands.labels([name]).inc();
      if (context is IInteractionContext) {
        totalSlashCommands.labels([name]).inc();
      } else {
        totalTextCommands.labels([name]).inc();
      }
    });

    Counter totalCommandsFailed = Counter(name: 'nyxx_total_commands_failed', help: 'The number of commands that failed', labelNames: ['error', 'name'])
      ..register();

    commands.onCommandError.listen((error) {
      if (error is CommandInvocationException) {
        String name = error.context.command is ChatCommand ? (error.context.command as ChatCommand).fullName : error.context.command.name;
        String errorName = (error is UncaughtException ? error.exception.runtimeType : error.runtimeType).toString();

        totalCommandsFailed.labels([errorName, name]).inc();
      }
    });

    Histogram commandExecutionTime = Histogram.exponential(
      name: 'nyxx_command_execution_time',
      help: 'The time each command took to execute',
      start: 1,
      factor: pow(const Duration(minutes: 15).inMicroseconds, 0.1).toDouble(),
      count: 10,
      labelNames: ['name'],
    )..register();

    Expando<DateTime> contextStartTimes = Expando();

    commands.onPreCall.listen((context) => contextStartTimes[context] = DateTime.now());

    void handleDone(IContext context) {
      DateTime? start = contextStartTimes[context];

      if (start == null) {
        return;
      }

      Duration executionTime = DateTime.now().difference(start);
      String name = context.command is ChatCommand ? (context.command as ChatCommand).fullName : context.command.name;

      commandExecutionTime.labels([name]).observe(executionTime.inMilliseconds.toDouble());
    }

    commands.onPostCall.listen(handleDone);
    commands.onCommandError
        .where((error) => error is CommandInvocationException)
        .cast<CommandInvocationException>()
        .listen((error) => handleDone(error.context));
  }

  Future<void> startHttpServer() async {
    Router router = Router()..get('/metrics', prometheusHandler());
    Handler handler = Pipeline().addMiddleware(shelf_metrics.register()).addHandler(router);

    HttpServer server = await serve(handler, '0.0.0.0', 8080);
    _logger.info('Serving at http://${server.address.host}:${server.port}');
  }
}
