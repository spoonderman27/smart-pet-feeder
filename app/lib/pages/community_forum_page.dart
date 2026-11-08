import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

String _forumTime(Timestamp? ts) {
  if (ts == null) return 'just now';
  return timeAgo(ts.toDate());
}

class CommunityForumPage extends StatefulWidget {
  const CommunityForumPage({super.key});

  @override
  State<CommunityForumPage> createState() => _CommunityForumPageState();
}

class _CommunityForumPageState extends State<CommunityForumPage> {
  final _posts = FirebaseFirestore.instance.collection('forum_posts');
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _stream =
      _posts.orderBy('lastActivity', descending: true).limit(100).snapshots();
  String _query = '';

  Future<void> _newPost() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _NewPostDialog(),
    );
    if (created == true && mounted) showSnack(context, 'Topic posted');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Community forum')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-topic',
        onPressed: _newPost,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New topic'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: PageBody(
              maxWidth: 900,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search topics',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _stream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                      child: EmptyState(
                          icon: Icons.error_outline,
                          title: 'Could not load the forum',
                          message: snap.error.toString()));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs.where((d) {
                  if (_query.isEmpty) return true;
                  final data = d.data();
                  return '${data['title']} ${data['content']}'
                      .toLowerCase()
                      .contains(_query);
                }).toList();
                if (docs.isEmpty) {
                  return const Center(
                    child: EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'No topics yet',
                      message: 'Start the first discussion!',
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  itemCount: docs.length,
                  separatorBuilder: (_, i) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    final d = doc.data();
                    return PageBody(
                      maxWidth: 900,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ThreadViewPage(postId: doc.id),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d['title'] as String? ?? 'Untitled',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800)),
                                const SizedBox(height: 4),
                                Text(d['content'] as String? ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Text('${d['flag'] ?? '🏳️'} ',
                                        style: const TextStyle(fontSize: 14)),
                                    Expanded(
                                      child: Text(
                                        '${d['author'] ?? 'User'} · ${_forumTime(d['lastActivity'] as Timestamp?)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                    const Icon(Icons.chat_bubble_outline, size: 16),
                                    const SizedBox(width: 4),
                                    Text('${d['replies'] ?? 0}',
                                        style: theme.textTheme.bodySmall),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NewPostDialog extends StatefulWidget {
  const _NewPostDialog();

  @override
  State<_NewPostDialog> createState() => _NewPostDialogState();
}

class _NewPostDialogState extends State<_NewPostDialog> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _posting = false;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    if (_title.text.trim().isEmpty || _content.text.trim().isEmpty) {
      showSnack(context, 'Please fill in the title and content', error: true);
      return;
    }
    setState(() => _posting = true);
    try {
      final me = await AuthService.instance.displayIdentity();
      await FirebaseFirestore.instance.collection('forum_posts').add({
        'authorUid': FirebaseAuth.instance.currentUser?.uid,
        'author': me.name,
        'flag': me.flag,
        'title': _title.text.trim(),
        'content': _content.text.trim(),
        'replies': 0,
        'timestamp': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _posting = false);
        showSnack(context, 'Failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New topic'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _content,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'What would you like to ask or share?',
                  alignLabelWithHint: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _posting ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _posting ? null : _post,
          child: _posting
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Post'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Thread view
// ===========================================================================

class ThreadViewPage extends StatefulWidget {
  final String postId;
  const ThreadViewPage({super.key, required this.postId});

  @override
  State<ThreadViewPage> createState() => _ThreadViewPageState();
}

class _ThreadViewPageState extends State<ThreadViewPage> {
  late final DocumentReference<Map<String, dynamic>> _postRef =
      FirebaseFirestore.instance.collection('forum_posts').doc(widget.postId);
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _post =
      _postRef.snapshots();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _replies =
      _postRef.collection('replies').orderBy('timestamp').snapshots();
  final _reply = TextEditingController();
  bool _sending = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final me = await AuthService.instance.displayIdentity();
      await _postRef.collection('replies').add({
        'authorUid': _uid,
        'author': me.name,
        'flag': me.flag,
        'content': text,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _postRef.update({
        'lastActivity': FieldValue.serverTimestamp(),
        'replies': FieldValue.increment(1),
      });
      _reply.clear();
      if (mounted) FocusScope.of(context).unfocus();
    } catch (e) {
      if (mounted) showSnack(context, 'Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deletePost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this topic?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final replies = await _postRef.collection('replies').get();
      for (final r in replies.docs) {
        if (r.data()['authorUid'] == _uid) await r.reference.delete();
      }
      await _postRef.delete();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, 'Failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _post,
      builder: (context, postSnap) {
        final post = postSnap.data?.data();
        final mine = post != null && post['authorUid'] == _uid;
        return Scaffold(
          appBar: AppBar(
            title: Text(post?['title'] as String? ?? 'Topic',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (mine)
                IconButton(
                  tooltip: 'Delete topic',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deletePost,
                ),
            ],
          ),
          body: post == null
              ? Center(
                  child: postSnap.connectionState == ConnectionState.waiting
                      ? const CircularProgressIndicator()
                      : const EmptyState(
                          icon: Icons.delete_outline,
                          title: 'This topic was deleted'))
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          PageBody(
                            maxWidth: 900,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        _AuthorRow(
                                          flag: post['flag'] as String?,
                                          author: post['author'] as String?,
                                          time: post['timestamp'] as Timestamp?,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(post['title'] as String? ?? '',
                                            style: theme.textTheme.titleLarge
                                                ?.copyWith(fontWeight: FontWeight.w800)),
                                        const SizedBox(height: 8),
                                        SelectableText(post['content'] as String? ?? '',
                                            style: theme.textTheme.bodyLarge),
                                      ],
                                    ),
                                  ),
                                ),
                                const SectionHeader('Replies'),
                                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                                  stream: _replies,
                                  builder: (context, snap) {
                                    if (!snap.hasData) {
                                      return const Center(
                                          child: CircularProgressIndicator());
                                    }
                                    final docs = snap.data!.docs;
                                    if (docs.isEmpty) {
                                      return const Text('No replies yet - be the first!');
                                    }
                                    return Column(
                                      children: [
                                        for (final r in docs)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: Card(
                                              child: Padding(
                                                padding: const EdgeInsets.all(14),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    _AuthorRow(
                                                      flag: r.data()['flag'] as String?,
                                                      author:
                                                          r.data()['author'] as String?,
                                                      time: r.data()['timestamp']
                                                          as Timestamp?,
                                                      onDelete: r.data()['authorUid'] ==
                                                              _uid
                                                          ? () async {
                                                              await r.reference.delete();
                                                              await _postRef.update({
                                                                'replies':
                                                                    FieldValue.increment(-1)
                                                              });
                                                            }
                                                          : null,
                                                    ),
                                                    const SizedBox(height: 8),
                                                    SelectableText(
                                                        r.data()['content'] as String? ??
                                                            ''),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          border: Border(top: BorderSide(color: theme.dividerColor)),
                        ),
                        child: PageBody(
                          maxWidth: 900,
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _reply,
                                  minLines: 1,
                                  maxLines: 4,
                                  textCapitalization: TextCapitalization.sentences,
                                  decoration: const InputDecoration(
                                      hintText: 'Write a reply...'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                onPressed: _sending ? null : _send,
                                icon: const Icon(Icons.send),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _AuthorRow extends StatelessWidget {
  final String? flag;
  final String? author;
  final Timestamp? time;
  final Future<void> Function()? onDelete;

  const _AuthorRow({this.flag, this.author, this.time, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
          child: Text(flag ?? '🏳️', style: const TextStyle(fontSize: 14)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: author ?? 'User',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              TextSpan(
                  text: '  ·  ${_forumTime(time)}',
                  style: theme.textTheme.bodySmall),
            ]),
          ),
        ),
        if (onDelete != null)
          IconButton(
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: onDelete,
          ),
      ],
    );
  }
}
