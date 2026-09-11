import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:re_highlight/re_highlight.dart';

/// 旧版自研 Markdown 色板（Cursor / GitHub Dark 感）。
Map<String, TextStyle> markdownEditorHighlightTheme(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return const {
      'root': TextStyle(color: Color(0xFFE6EDF3)),
      'section': TextStyle(color: Color(0xFF79B8FF)),
      'meta': TextStyle(color: Color(0xFF6B737E)),
      'strong': TextStyle(color: Color(0xFFE6C07B)),
      'emphasis': TextStyle(color: Color(0xFFB4E0A0)),
      'code': TextStyle(color: Color(0xFFFFAB70)),
      'quote': TextStyle(color: Color(0xFF8B949E)),
      'bullet': TextStyle(color: Color(0xFFD2A8FF)),
      'string': TextStyle(color: Color(0xFF58A6FF)),
      'link': TextStyle(color: Color(0xFF7EE787)),
      'symbol': TextStyle(color: Color(0xFFFFA657)),
      'deletion': TextStyle(color: Color(0xFF8B949E)),
      'addition': TextStyle(color: Color(0xFFE6C07B)),
      'name': TextStyle(color: Color(0xFFFF7B72)),
      'tag': TextStyle(color: Color(0xFFFF7B72)),
      'attr': TextStyle(color: Color(0xFFD2A8FF)),
      'attribute': TextStyle(color: Color(0xFFD2A8FF)),
      'literal': TextStyle(color: Color(0xFF79B8FF)),
      'title': TextStyle(color: Color(0xFFD2A8FF)),
      'keyword': TextStyle(color: Color(0xFFFF7B72)),
      'built_in': TextStyle(color: Color(0xFFE6C07B)),
      'number': TextStyle(color: Color(0xFFD2A8FF)),
      'comment': TextStyle(color: Color(0xFF6B737E)),
      'type': TextStyle(color: Color(0xFFE6C07B)),
      'variable': TextStyle(color: Color(0xFFD2A8FF)),
      'params': TextStyle(color: Color(0xFFE6EDF3)),
      'regexp': TextStyle(color: Color(0xFF7EE787)),
      'subst': TextStyle(color: Color(0xFFE6EDF3)),
      'doctag': TextStyle(color: Color(0xFFD2A8FF)),
      'formula': TextStyle(color: Color(0xFFE6EDF3)),
      'selector-tag': TextStyle(color: Color(0xFFFF7B72)),
      'selector-class': TextStyle(color: Color(0xFFE6C07B)),
      'selector-id': TextStyle(color: Color(0xFF79B8FF)),
    };
  }
  return const {
    'root': TextStyle(color: Color(0xFF1F2328)),
    'section': TextStyle(color: Color(0xFF0550AE)),
    'meta': TextStyle(color: Color(0xFF6E7781)),
    'strong': TextStyle(color: Color(0xFF953800)),
    'emphasis': TextStyle(color: Color(0xFF116329)),
    'code': TextStyle(color: Color(0xFFCF222E)),
    'quote': TextStyle(color: Color(0xFF6E7781)),
    'bullet': TextStyle(color: Color(0xFF8250DF)),
    'string': TextStyle(color: Color(0xFF0969DA)),
    'link': TextStyle(color: Color(0xFF1A7F37)),
    'symbol': TextStyle(color: Color(0xFFBC4C00)),
    'deletion': TextStyle(color: Color(0xFF6E7781)),
    'addition': TextStyle(color: Color(0xFF953800)),
    'name': TextStyle(color: Color(0xFFCF222E)),
    'tag': TextStyle(color: Color(0xFFCF222E)),
    'attr': TextStyle(color: Color(0xFF8250DF)),
    'attribute': TextStyle(color: Color(0xFF8250DF)),
    'literal': TextStyle(color: Color(0xFF0550AE)),
    'title': TextStyle(color: Color(0xFF8250DF)),
    'keyword': TextStyle(color: Color(0xFFCF222E)),
    'built_in': TextStyle(color: Color(0xFF953800)),
    'number': TextStyle(color: Color(0xFF8250DF)),
    'comment': TextStyle(color: Color(0xFF6E7781)),
    'type': TextStyle(color: Color(0xFF953800)),
    'variable': TextStyle(color: Color(0xFF8250DF)),
    'params': TextStyle(color: Color(0xFF1F2328)),
    'regexp': TextStyle(color: Color(0xFF116329)),
    'subst': TextStyle(color: Color(0xFF1F2328)),
    'doctag': TextStyle(color: Color(0xFF8250DF)),
    'formula': TextStyle(color: Color(0xFF1F2328)),
    'selector-tag': TextStyle(color: Color(0xFFCF222E)),
    'selector-class': TextStyle(color: Color(0xFF953800)),
    'selector-id': TextStyle(color: Color(0xFF0550AE)),
  };
}

List<Mode> get _inlineRules => <Mode>[
      // 图片 ![alt](url)
      Mode(
        begin: r'!\[[^\]]*\]\([^)]*\)',
        returnBegin: true,
        contains: <Mode>[
          Mode(className: 'meta', begin: r'!\[', end: r'\]', excludeEnd: true),
          Mode(
            className: 'link',
            begin: r'\(',
            end: r'\)',
            excludeBegin: true,
            excludeEnd: true,
          ),
        ],
        relevance: 6,
      ),
      // 链接 [text](url)
      Mode(
        begin: r'\[[^\]]+\]\([^)]*\)',
        returnBegin: true,
        contains: <Mode>[
          Mode(
            className: 'string',
            begin: r'\[',
            end: r'\]',
            excludeBegin: true,
            excludeEnd: true,
          ),
          Mode(
            className: 'link',
            begin: r'\(',
            end: r'\)',
            excludeBegin: true,
            excludeEnd: true,
          ),
        ],
        relevance: 5,
      ),
      // 中括号：【…】与独立 […]（不含链接 [text](url)）
      Mode(className: 'string', begin: r'【[^】\n]+】', relevance: 3),
      Mode(
        className: 'string',
        begin: r'\[[^\]\n]+\](?!\()',
        relevance: 2,
      ),
      Mode(className: 'link', begin: r'<https?://[^>\s]+>', relevance: 3),
      Mode(className: 'tag', begin: r'</?[A-Za-z][^>\n]*>', relevance: 2),
      Mode(className: 'code', begin: r'`[^`\n]+`', relevance: 5),
      Mode(className: 'strong', begin: r'\*\*\*[^*\n]+?\*\*\*', relevance: 3),
      Mode(className: 'strong', begin: r'\*\*[^*\n]+?\*\*', relevance: 2),
      Mode(className: 'strong', begin: r'__[^_\n]+?__', relevance: 2),
      // 斜体只用 *，避免 _snake_case_
      Mode(className: 'emphasis', begin: r'\*[^*\n]+?\*', relevance: 1),
      Mode(className: 'deletion', begin: r'~~[^~\n]+?~~', relevance: 1),
      Mode(className: 'addition', begin: r'==[^=\n]+?==', relevance: 1),
    ];

/// 对齐旧版覆盖面：标题/代码/链接/粗斜体/引用/列表/任务/HTML/表格/高亮。
/// 全部用「成对标记」或「行首到行尾」，避免跨整篇串色。
final Mode langMarkdownRich = Mode(
  name: 'Markdown',
  aliases: const ['md', 'mkdown', 'mkd'],
  disableAutodetect: true,
  contains: <Mode>[
    Mode(
      className: 'code',
      begin: r'^```[\w+-]*',
      end: r'^```\s*$',
      relevance: 10,
    ),
    Mode(
      className: 'code',
      begin: r'^~~~[\w+-]*',
      end: r'^~~~\s*$',
      relevance: 10,
    ),
    // 标题整行 section；# 另行 meta（同一行内结束）
    Mode(
      className: 'section',
      begin: r'^#{1,6}[ \t].*$',
      relevance: 10,
    ),
    Mode(
      className: 'meta',
      begin: r'^#{1,6}(?=[ \t])',
      relevance: 10,
    ),
    Mode(
      className: 'quote',
      begin: r'^ {0,3}>[ \t]?.*$',
      relevance: 5,
    ),
    Mode(
      className: 'literal',
      begin: r'^(\s*)([*+-]|\d+[.)])(\s+)\[[ xX]\](?=\s)',
      relevance: 6,
    ),
    Mode(
      className: 'bullet',
      begin: r'^(\s*)([*+-]|\d+[.)])(?=\s)',
      relevance: 4,
    ),
    Mode(
      className: 'meta',
      begin: r'^ {0,3}([-*_])( *\1){2,}[ \t]*$',
      relevance: 3,
    ),
    // 表格分隔行：整行淡化
    Mode(
      className: 'meta',
      begin: r'^ {0,3}\|?[\s:|-]+\|[\s:|-]*\|?[ \t]*$',
      relevance: 2,
    ),
    // 表格内容行：只把 | 标成 meta，单元格走 inline（**粗体** / HTML 等）
    Mode(
      begin: r'^ {0,3}\|',
      end: r'$',
      contains: <Mode>[
        Mode(className: 'meta', begin: r'\|'),
        ..._inlineRules,
      ],
      relevance: 2,
    ),
    ..._inlineRules,
  ],
);
