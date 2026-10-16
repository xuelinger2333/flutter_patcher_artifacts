import 'package:flutter/material.dart';

Widget patchEntry() => Container(
  color: Colors.transparent,
  padding: const EdgeInsets.all(8),
  child: const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [SizedBox(width: 12, height: 8), Text('patch')],
  ),
);
