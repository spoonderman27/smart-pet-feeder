import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  final _formKey = GlobalKey<FormState>();
  final _message = TextEditingController();
  String _type = 'Bug Report';
  bool _sending = false;

  final _tickets = FirebaseFirestore.instance.collection('support_tickets');
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _myTickets = _tickets
      .where('uid', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
      .snapshots();

  static const _types = ['Bug Report', 'Feature Request', 'Hardware Issue', 'Other'];

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final user = FirebaseAuth.instance.currentUser;
    setState(() => _sending = true);
    try {
      await _tickets.add({
        'uid': user?.uid,
        'user_email': user?.email ?? 'Anonymous',
        'type': _type,
        'message': _message.text.trim(),
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'open',
      });
      _message.clear();
      if (mounted) showSnack(context, 'Thank you! Your ticket was submitted.');
    } catch (e) {
      if (mounted) showSnack(context, 'Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback & support')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          PageBody(
            maxWidth: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('How can we help?',
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text('Report a problem with the feeder or app, or suggest a feature.',
                              style: theme.textTheme.bodyMedium),
                          const SizedBox(height: 20),
                          DropdownButtonFormField<String>(
                            initialValue: _type,
                            decoration: const InputDecoration(
                              labelText: 'Type',
                              prefixIcon: Icon(Icons.category_outlined),
                            ),
                            items: [
                              for (final t in _types)
                                DropdownMenuItem(value: t, child: Text(t)),
                            ],
                            onChanged: (v) => setState(() => _type = v ?? _type),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _message,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              labelText: 'Describe the issue or idea',
                              alignLabelWithHint: true,
                            ),
                            validator: (v) => (v == null || v.trim().length < 10)
                                ? 'Please write at least 10 characters'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _sending ? null : _submit,
                            icon: const Icon(Icons.send),
                            label: const Text('Submit'),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Or email ${AppConfig.supportEmail}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SectionHeader('My tickets'),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _myTickets,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Text('Could not load tickets: ${snap.error}');
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data!.docs.toList()
                      ..sort((a, b) {
                        final t1 = a.data()['timestamp'] as Timestamp?;
                        final t2 = b.data()['timestamp'] as Timestamp?;
                        if (t1 == null) return -1;
                        if (t2 == null) return 1;
                        return t2.compareTo(t1);
                      });
                    if (docs.isEmpty) {
                      return const Card(
                          child: EmptyState(
                              icon: Icons.inbox_outlined,
                              title: 'No tickets yet'));
                    }
                    return Column(
                      children: [
                        for (final doc in docs)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _TicketCard(data: doc.data()),
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
    );
  }
}

class _TicketCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TicketCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = data['status'] == 'resolved';
    final color = resolved ? AppTheme.ok : AppTheme.warn;
    final ts = data['timestamp'] as Timestamp?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(data['type'] as String? ?? 'Ticket',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text((data['status'] as String? ?? 'open').toUpperCase(),
                      style: TextStyle(
                          color: color, fontWeight: FontWeight.w800, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(data['message'] as String? ?? ''),
            const SizedBox(height: 6),
            Text(formatDateTime(ts?.toDate()), style: theme.textTheme.bodySmall),
            if (data['admin_reply'] != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.water.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.support_agent, size: 16, color: AppTheme.water),
                      SizedBox(width: 6),
                      Text('Admin reply',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, color: AppTheme.water)),
                    ]),
                    const SizedBox(height: 6),
                    Text(data['admin_reply'].toString()),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
