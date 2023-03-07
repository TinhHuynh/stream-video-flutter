import 'package:equatable/equatable.dart';

import 'call_metadata.dart';

class CallReaction with EquatableMixin {
  const CallReaction({
    required this.reactionType,
    required this.user,
    this.emojiCode,
    this.custom = const {},
  });

  final String reactionType;
  final String? emojiCode;
  final CallUser user;
  final Map<String, Object>? custom;

  @override
  bool? get stringify => true;

  @override
  List<Object?> get props => [reactionType, user, emojiCode, custom];
}