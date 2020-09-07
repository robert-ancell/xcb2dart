import 'dart:io';

import 'package:xml/xml.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Requires XCB xml proto file');
    return;
  }
  var protoFile = args[0];

  var xml = await File(protoFile).readAsString();
  var document = XmlDocument.parse(xml);
  var xcb = document.getElement('xcb');

  var classes = <String>[];
  var functions = <String>[];
  for (var request in xcb.findElements('request')) {
    var name = request.getAttribute('name');
    var opcode = request.getAttribute('opcode');
    var reply = request.getElement('reply');
    var fields = getFields(request);
    var namedArgs = fields.length > 1;

    classes.add(makeMessageClass(request, name, 'Request'));
    if (reply != null) {
      classes.add(makeMessageClass(reply, name, 'Reply'));
    }

    var functionName = requestNameToFunctionName(name);
    String returnValue;
    String returnName;
    var functionSuffix = '';
    if (reply != null) {
      var replyFields = getFields(reply);
      if (replyFields.length == 1) {
        returnName = replyFields.keys.first;
        returnValue = 'Future<${replyFields.values.first}>';
      } else {
        returnValue = 'Future<X11${name}Reply>';
      }
      functionSuffix = ' async';
    } else {
      returnValue = 'int';
    }

    var constructorArgs = <String>[];
    var args = <String>[];
    fields.forEach((name, type) {
      if (namedArgs) {
        constructorArgs.add('${name}: ${name}');
      } else {
        constructorArgs.add(name);
      }
      args.add('${type} ${name}');
    });

    var code = '';
    code +=
        '  ${returnValue} ${functionName}(${args.join(', ')})${functionSuffix} {\n';
    code +=
        '    var request = X11${name}Request(${constructorArgs.join(', ')});\n';
    code += '    var buffer = X11WriteBuffer();\n';
    code += '    request.encode(buffer);\n';
    if (reply != null) {
      code +=
          '    var sequenceNumber = _sendRequest(${opcode}, buffer.data);\n';
      if (returnName != null) {
        code +=
            '    var reply = await _awaitReply<X11${name}Reply>(sequenceNumber, X11${name}Reply.fromBuffer);\n';
        code += '    return reply.${returnName};\n';
      } else {
        code +=
            '    return _awaitReply<X11${name}Reply>(sequenceNumber, X11${name}Reply.fromBuffer);\n';
      }
    } else {
      code += '    return _sendRequest(${opcode}, buffer.data);\n';
    }
    code += '  }\n';
    functions.add(code);
  }

  for (var event in xcb.findElements('event')) {
    var name = event.getAttribute('name');
    classes.add(makeMessageClass(event, name, 'Event'));
  }

  var module = '';
  module += classes.join('\n');
  module += 'class X11Client {\n';
  module += functions.join('\n');
  module += '}';

  print(module);
}

Map<String, String> getFields(XmlElement element) {
  var refs = getRefFields(element);

  var fields = <String, String>{};
  for (var element in getFieldElements(element)) {
    var fieldName = element.getAttribute('name');
    if (refs.contains(fieldName)) {
      continue;
    }

    var fieldType = makeFieldDartType(element);
    if (fieldType != null) {
      fields[xcbFieldToDartName(fieldName)] = fieldType;
      ;
    }
  }

  return fields;
}

Set<String> getRefFields(XmlElement element) {
  var refs = <String>{};
  for (var list
      in getFieldElements(element).where((e) => e.name.local == 'list')) {
    var fieldref = list.getElement('fieldref');
    if (fieldref != null) {
      refs.add(fieldref.text);
    }
  }

  return refs;
}

String makeMessageClass(XmlElement element, String name, String suffix) {
  var fieldElements = getFieldElements(element);
  var fields = getFields(element);
  var namedArgs = fields.length > 1;

  var constructorArgNames = <String>[];
  var argNames = <String>[];
  var args = <String>[];
  fields.forEach((name, type) {
    constructorArgNames.add('this.${name}');
    if (namedArgs) {
      argNames.add('${name}: ${name}');
    } else {
      argNames.add(name);
    }
    args.add('${type} ${name}');
  });

  var code = '';
  code += 'class X11${name}${suffix} extends X11${suffix} {\n';
  for (var arg in args) {
    code += '  final ${arg};\n';
  }
  code += '\n';
  var argList = constructorArgNames.join(', ');
  if (namedArgs) {
    argList = '{' + argList + '}';
  }
  code += '  X11${name}${suffix}(${argList});\n';
  code += '\n';
  code += '  factory X11${name}${suffix}.fromBuffer(X11ReadBuffer buffer) {\n';
  for (var field in fieldElements) {
    var call = makeReadCall(field);
    if (call != null) {
      code += '    ${call};\n';
    }
  }
  code += '    return X11${name}${suffix}(${argNames.join(', ')});\n';
  code += '  }\n';
  code += '\n';
  code += '  @override\n';
  code += '  void encode(X11WriteBuffer buffer) {\n';
  for (var element in fieldElements) {
    var call = makeWriteCall(element);
    if (call != null) {
      code += '    ${call};\n';
    }
  }
  code += '  }\n';
  code += '}\n';

  return code;
}

Iterable<XmlElement> getFieldElements(XmlElement element) {
  return element.children
      .where((node) => node is XmlElement)
      .map((node) => node as XmlElement);
}

String makeFieldDartType(XmlElement element) {
  if (element.name.local == 'field') {
    var fieldType = element.getAttribute('type');
    return xcbTypeToDartType(fieldType);
  } else if (element.name.local == 'list') {
    var listType = element.getAttribute('type');

    if (listType == 'char') {
      return 'String';
    } else {
      return 'List<${xcbTypeToDartType(listType)}>';
    }
  }
}

String makeFieldDartName(XmlElement element) {
  if (element.name.local == 'field') {
    var fieldName = element.getAttribute('name');
    return xcbFieldToDartName(fieldName);
  } else if (element.name.local == 'list') {
    var listName = element.getAttribute('name');
    return xcbFieldToDartName(listName);
  }
}

String makeReadCall(XmlElement element) {
  if (element.name.local == 'pad') {
    var count = element.getAttribute('bytes');
    var align = element.getAttribute('align');
    if (count != null) {
      return 'buffer.skip(${count})';
    } else if (align != null) {
      return 'buffer.align(${align})';
    }
  } else if (element.name.local == 'field') {
    var fieldType = element.getAttribute('type');
    var fieldName = element.getAttribute('name');
    return 'var ${xcbFieldToDartName(fieldName)} = buffer.read${xcbTypeToBufferType(fieldType)}()';
  }
}

String makeWriteCall(XmlElement element) {
  if (element.name.local == 'pad') {
    var count = element.getAttribute('bytes');
    var align = element.getAttribute('align');
    if (count != null) {
      return 'buffer.skip(${count})';
    } else if (align != null) {
      return 'buffer.align(${align})';
    }
  } else if (element.name.local == 'field') {
    var fieldType = element.getAttribute('type');
    var fieldName = element.getAttribute('name');
    return 'buffer.write${xcbTypeToBufferType(fieldType)}(${xcbFieldToDartName(fieldName)})';
  }
}

String xcbTypeToDartType(String type) {
  if (type == 'BOOL') {
    return 'bool';
  } else if (type == 'BYTE') {
    return 'int';
  } else if (type == 'CARD8' || type == 'CARD16' || type == 'CARD32') {
    return 'int';
  } else if (type == 'INT8' || type == 'INT16' || type == 'INT32') {
    return 'int';
  } else if (type == 'ATOM' ||
      type == 'COLORMAP' ||
      type == 'CURSOR' ||
      type == 'DRAWABLE' ||
      type == 'FONT' ||
      type == 'FONTABLE' ||
      type == 'GCONTEXT' ||
      type == 'KEYCODE' ||
      type == 'KEYSYM' ||
      type == 'PIXMAP' ||
      type == 'TIMESTAMP' ||
      type == 'VISUALID' ||
      type == 'WINDOW') {
    return 'int';
  }
  return '?${type}?';
}

String xcbTypeToBufferType(String type) {
  if (type == 'BOOL') {
    return 'Bool';
  } else if (type == 'BYTE' || type == 'CARD8') {
    return 'Uint8';
  } else if (type == 'CARD16') {
    return 'Uint16';
  } else if (type == 'ATOM' ||
      type == 'CARD32' ||
      type == 'COLORMAP' ||
      type == 'CURSOR' ||
      type == 'DRAWABLE' ||
      type == 'FONT' ||
      type == 'FONTABLE' ||
      type == 'GCONTEXT' ||
      type == 'KEYCODE' ||
      type == 'KEYSYM' ||
      type == 'PIXMAP' ||
      type == 'TIMESTAMP' ||
      type == 'VISUALID' ||
      type == 'WINDOW') {
    return 'Uint32';
  } else if (type == 'INT8') {
    return 'Int8';
  } else if (type == 'INT16') {
    return 'Int16';
  } else if (type == 'INT32') {
    return 'Int32';
  }
  return '?${type}?';
}

String requestNameToFunctionName(String name) {
  return name[0].toLowerCase() + name.substring(1);
}

String xcbFieldToDartName(String name) {
  var dartName = '';
  var makeUpper = false;
  for (var i = 0; i < name.length; i++) {
    if (makeUpper) {
      dartName += name[i].toUpperCase();
      makeUpper = false;
    } else if (name[i] == '_') {
      makeUpper = true;
    } else {
      dartName += name[i];
    }
  }
  if (makeUpper) dartName += '_';

  return dartName;
}
