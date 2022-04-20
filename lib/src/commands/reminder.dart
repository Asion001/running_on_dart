import 'package:nyxx/nyxx.dart';
import 'package:nyxx_commands/nyxx_commands.dart';
import 'package:nyxx_pagination/nyxx_pagination.dart';
import 'package:running_on_dart/src/models/reminder.dart';
import 'package:running_on_dart/src/services/reminder.dart';
import 'package:running_on_dart/src/util.dart';

ChatGroup reminder = ChatGroup(
  'reminder',
  'Create and manage reminders',
  children: [
    ChatCommand(
      'create',
      'Create a new reminder',
      (
        IChatContext context,
        @Name('in') @Description('The amount of time after which the reminder should trigger') Duration offset,
        @Description('A short message to attach to the reminder') String message,
      ) async {
        DateTime triggerAt = DateTime.now().add(offset);

        await addReminder(Reminder(
          userId: context.user.id,
          channelId: context.channel.id,
          messageId: context is MessageChatContext ? context.message.id : null,
          triggerAt: triggerAt,
          addedAt: DateTime.now(),
          message: message,
        ));

        await context.respond(
          MessageBuilder.content('Alright ')
            ..appendMention(context.user)
            ..append(', ')
            ..appendTimestamp(triggerAt, style: TimeStampStyle.relativeTime)
            ..append(': ')
            ..append(message),
        );
      },
    ),
    ChatCommand(
      'clear',
      'Remove all your reminders',
      (IChatContext context) async {
        await Future.wait(getUserReminders(context.user.id).map((reminder) => removeReminder(reminder)));

        await context.respond(MessageBuilder.content('Successfully cleared all your reminders.'));
      },
    ),
    ChatCommand(
      'remove',
      'Remove a reminder',
      (
        IChatContext context,
        @Description('The reminder to remove') Reminder reminder,
      ) async {
        await removeReminder(reminder);

        await context.respond(MessageBuilder.content('Successfully removed your reminder.'));
      },
    ),
    ChatCommand(
      'list',
      'List all your active reminders',
      (IChatContext context) async {
        List<Reminder> reminders = getUserReminders(context.user.id).toList()..sort((a, b) => a.triggerAt.compareTo(b.triggerAt));

        EmbedComponentPagination paginator = EmbedComponentPagination(
          context.commands.interactions,
          reminders.asMap().entries.map((entry) {
            int index = entry.key;
            Reminder reminder = entry.value;

            return EmbedBuilder()
              ..color = getRandomColor()
              ..title = 'Reminder ${index + 1} of ${reminders.length}'
              ..addField(
                name: 'Triggers at',
                content: '${TimeStampStyle.longDateTime.format(reminder.triggerAt)} (${TimeStampStyle.relativeTime.format(reminder.triggerAt)})',
              )
              ..addField(name: 'Content', content: reminder.message.length > 2048 ? reminder.message.substring(0, 2045) + '...' : reminder.message);
          }).toList(),
        );

        await context.respond(paginator.initMessageBuilder());
      },
    ),
  ],
);