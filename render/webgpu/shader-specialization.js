// SPDX-License-Identifier: GPL-3.0-or-later
// The checked-in WGSL remains the source of truth. Remove material families
// proven inactive by immutable packet metadata before handing WGSL to the
// driver. This avoids compiling every OpenMW shading family for each pipeline.
// Unknown expressions remain intact; no source text is executed as JavaScript.

const UNKNOWN = Symbol('unknown WGSL expression');
const allRoots = ['vertex_main', 'fragment_color', 'fragment_normal', 'fragment_depth', 'fragment_query'];
const binaryPrecedence = new Map([
  ['||', 1], ['&&', 2], ['|', 3], ['^', 4], ['&', 5], ['==', 6], ['!=', 6],
  ['<', 7], ['<=', 7], ['>', 7], ['>=', 7], ['<<', 8], ['>>', 8],
  ['+', 9], ['-', 9], ['*', 10], ['/', 10], ['%', 10],
]);
const value = (number, type = 'u32') => ({value: number, type});
const bool = condition => value(Boolean(condition), 'bool');

function maskComments(source) {
  const result = source.split('');
  let block = 0, line = false;
  for (let i = 0; i < source.length; i++) {
    const pair = source.slice(i, i + 2);
    if (line) { if (source[i] === '\n') line = false; else result[i] = ' '; continue; }
    if (block) {
      if (pair === '/*') { result[i] = result[i + 1] = ' '; block++; i++; }
      else if (pair === '*/') { result[i] = result[i + 1] = ' '; block--; i++; }
      else if (source[i] !== '\n') result[i] = ' ';
      continue;
    }
    if (pair === '//') { result[i] = result[i + 1] = ' '; line = true; i++; }
    else if (pair === '/*') { result[i] = result[i + 1] = ' '; block = 1; i++; }
  }
  return result.join('');
}

function evaluate(condition, constants) {
  const tokens = condition.match(/0x[0-9a-f]+[ui]?|(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?[uif]?|[A-Za-z_]\w*|&&|\|\||==|!=|<=|>=|<<|>>|[^\s]/gi) ?? [];
  let cursor = 0;
  const cast = (number, type) => {
    if (number === UNKNOWN) return UNKNOWN;
    if (type === 'u32') return value(number.value >>> 0);
    if (type === 'i32') return value(number.value | 0, 'i32');
    return value(Math.fround(number.value), 'f32');
  };
  function primary() {
    const token = tokens[cursor++];
    if (token === undefined) throw new Error('Incomplete expression');
    if (token === '(') { const result = expression(0); if (tokens[cursor++] !== ')') throw new Error('Unbalanced expression'); return result; }
    if (['!', '~', '-', '+', '&', '*'].includes(token)) {
      const operand = primary();
      if (operand === UNKNOWN || token === '&' || token === '*') return UNKNOWN;
      if (token === '!') return bool(!operand.value);
      if (token === '~') return cast(value(~operand.value), operand.type);
      if (token === '-') return value(-operand.value, operand.type);
      return operand;
    }
    let result;
    if (/^(?:0x[\da-f]+|(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)[uif]?$/i.test(token)) {
      const hexadecimal = /^0x/i.test(token);
      const suffix = (hexadecimal ? /[ui]$/i : /[uif]$/i).test(token) ? token.slice(-1).toLowerCase() : '';
      const literal = suffix ? token.slice(0, -1) : token;
      result = value(Number(literal), suffix === 'f' || /[.e]/i.test(literal) && !/^0x/i.test(literal)
        ? 'f32' : suffix === 'i' ? 'i32' : 'u32');
    } else if (token === 'true' || token === 'false') result = bool(token === 'true');
    else if (/^[A-Za-z_]\w*$/.test(token)) {
      result = constants.get(token) ?? UNKNOWN;
      if (tokens[cursor] === '(') {
        cursor++; const args = [];
        if (tokens[cursor] !== ')') for (;;) {
          args.push(expression(0));
          if (tokens[cursor] !== ',') break;
          cursor++;
        }
        if (tokens[cursor++] !== ')') throw new Error('Unbalanced call');
        result = ['u32', 'i32', 'f32'].includes(token) && args.length === 1 ? cast(args[0], token) : UNKNOWN;
      }
    } else throw new Error('Unsupported expression token');
    while (tokens[cursor] === '.' || tokens[cursor] === '[') {
      if (tokens[cursor++] === '.') {
        if (!/^[A-Za-z_]\w*$/.test(tokens[cursor++] ?? '')) throw new Error('Invalid member');
      } else { expression(0); if (tokens[cursor++] !== ']') throw new Error('Invalid subscript'); }
      result = UNKNOWN;
    }
    return result;
  }
  function operation(operator, left, right) {
    if (operator === '&&') {
      if (left !== UNKNOWN && !left.value || right !== UNKNOWN && !right.value) return bool(false);
      return left === UNKNOWN || right === UNKNOWN ? UNKNOWN : bool(true);
    }
    if (operator === '||') {
      if (left !== UNKNOWN && left.value || right !== UNKNOWN && right.value) return bool(true);
      return left === UNKNOWN || right === UNKNOWN ? UNKNOWN : bool(false);
    }
    if (left === UNKNOWN || right === UNKNOWN) return UNKNOWN;
    const a = left.value, b = right.value;
    if (operator === '==') return bool(a === b);
    if (operator === '!=') return bool(a !== b);
    if (operator === '<') return bool(a < b);
    if (operator === '<=') return bool(a <= b);
    if (operator === '>') return bool(a > b);
    if (operator === '>=') return bool(a >= b);
    const type = left.type === 'f32' || right.type === 'f32' ? 'f32'
      : left.type === 'u32' || right.type === 'u32' ? 'u32' : 'i32';
    let number;
    if (operator === '&') number = a & b;
    else if (operator === '|') number = a | b;
    else if (operator === '^') number = a ^ b;
    else if (operator === '<<') number = a << b;
    else if (operator === '>>') number = left.type === 'u32' ? a >>> b : a >> b;
    else if (operator === '+') number = a + b;
    else if (operator === '-') number = a - b;
    else if (operator === '*') number = a * b;
    else if (operator === '/') { if (!b) return UNKNOWN; number = type === 'f32' ? a / b : Math.trunc(a / b); }
    else if (operator === '%') { if (!b) return UNKNOWN; number = a % b; }
    else return UNKNOWN;
    return type === 'f32' ? value(Math.fround(number), type) : cast(value(number), type);
  }
  function expression(minimum) {
    let left = primary();
    while ((binaryPrecedence.get(tokens[cursor]) ?? -1) >= minimum) {
      const operator = tokens[cursor++], priority = binaryPrecedence.get(operator);
      left = operation(operator, left, expression(priority + 1));
    }
    return left;
  }
  try {
    const result = expression(0);
    return cursor === tokens.length && result !== UNKNOWN && result.type === 'bool' ? result.value : UNKNOWN;
  } catch { return UNKNOWN; }
}

function structure(source) {
  const masked = maskComments(source), pairs = new Map(), stack = [];
  for (let index = 0; index < masked.length; index++) {
    if (masked[index] === '{') stack.push(index);
    else if (masked[index] === '}') {
      if (!stack.length) throw new Error('Unbalanced WGSL braces');
      pairs.set(stack.pop(), index);
    }
  }
  if (stack.length) throw new Error('Unbalanced WGSL braces');
  const functions = [], pattern = /\bfn\s+([A-Za-z_]\w*)\s*\(/g;
  for (let match; (match = pattern.exec(masked));) {
    const open = masked.indexOf('{', pattern.lastIndex), close = pairs.get(open);
    if (close === undefined) throw new Error(`Missing WGSL function body ${match[1]}`);
    // WGSL attributes belong to the declaration that follows them. Starting a
    // removable function at the "fn" token leaves e.g. "@fragment" orphaned,
    // which is invalid WGSL. Walk backwards over contiguous attribute lines
    // while preserving comments/other declarations before them.
    let declarationStart = match.index;
    const lineStart = masked.lastIndexOf('\n', match.index - 1) + 1;
    const currentPrefix = masked.slice(lineStart, match.index).trim();
    if (currentPrefix.startsWith('@')) declarationStart = lineStart;
    else if (currentPrefix === '') {
      // Attributes may be on one or more immediately preceding lines.
      let cursor = lineStart;
      while (cursor > 0) {
        const previousEnd = cursor - 1;
        const previousStart = masked.lastIndexOf('\n', previousEnd - 1) + 1;
        const previous = masked.slice(previousStart, previousEnd).trim();
        if (!previous.startsWith('@')) break;
        declarationStart = previousStart;
        cursor = previousStart;
      }
    }
    functions.push({name: match[1], start: declarationStart, fnStart: match.index, open, close, end: close + 1});
    pattern.lastIndex = close + 1;
  }
  return {masked, pairs, functions};
}

function foldFunction(source, parsed, fn, constants) {
  const {masked, pairs} = parsed;
  const skip = position => { while (/\s/.test(masked[position] ?? '') && position < masked.length) position++; return position; };
  const isWord = (position, word) => masked.slice(position, position + word.length) === word
    && !/\w/.test(masked[position - 1] ?? '') && !/\w/.test(masked[position + word.length] ?? '');
  function block(start, end) {
    const chunks = []; let cursor = start;
    const pattern = /\bif\b|\{/g; pattern.lastIndex = start;
    for (let match; (match = pattern.exec(masked)) && match.index < end;) {
      chunks.push(source.slice(cursor, match.index));
      if (match[0] === 'if') {
        const branch = conditional(match.index); chunks.push(branch.text); cursor = branch.end;
      } else {
        const close = pairs.get(match.index);
        chunks.push('{' + block(match.index + 1, close) + '}'); cursor = close + 1;
      }
      pattern.lastIndex = cursor;
    }
    chunks.push(source.slice(cursor, end)); return chunks.join('');
  }
  function conditional(start) {
    const open = masked.indexOf('{', start + 2), close = pairs.get(open);
    if (close === undefined) throw new Error('Missing WGSL conditional body');
    const expression = masked.slice(start + 2, open).trim(), known = evaluate(expression, constants);
    let end = close + 1, alternative = null, next = skip(end);
    if (isWord(next, 'else')) {
      next = skip(next + 4);
      if (isWord(next, 'if')) alternative = conditional(next);
      else if (masked[next] === '{') {
        const last = pairs.get(next);
        alternative = {text: '{' + block(next + 1, last) + '}', end: last + 1};
      } else throw new Error('Unsupported WGSL else statement');
      end = alternative.end;
    }
    if (known === true) return {text: '{' + block(open + 1, close) + '}', end};
    if (known === false) return {text: alternative?.text ?? '', end};
    return {text: source.slice(start, open + 1) + block(open + 1, close) + '}'
      + (alternative ? ' else ' + (alternative.text || '{}') : ''), end};
  }
  return source.slice(fn.start, fn.open + 1) + block(fn.open + 1, fn.close) + '}';
}

function pruneFunctions(source, roots = allRoots) {
  const parsed = structure(source), functions = new Map(parsed.functions.map(fn => [fn.name, fn]));
  const live = new Set(), pending = roots.filter(name => functions.has(name));
  while (pending.length) {
    const name = pending.pop(); if (live.has(name)) continue; live.add(name);
    const fn = functions.get(name), body = parsed.masked.slice(fn.open + 1, fn.close);
    for (const match of body.matchAll(/\b([A-Za-z_]\w*)\s*\(/g))
      if (functions.has(match[1]) && !live.has(match[1])) pending.push(match[1]);
  }
  let cursor = 0, result = '';
  for (const fn of parsed.functions) {
    result += source.slice(cursor, fn.start);
    if (live.has(fn.name)) result += source.slice(fn.start, fn.end);
    cursor = fn.end;
  }
  return result + source.slice(cursor);
}

export function specializeMaterialSource(source, values, fragmentEntryPoint = null) {
  if (typeof source !== 'string' || !values || typeof values !== 'object') throw new TypeError('Expected WGSL and material constants');
  const constants = new Map();
  for (const [name, number] of Object.entries(values)) {
    if (!/^[A-Za-z_]\w*$/.test(name) || !Number.isInteger(number) || number < 0 || number > 0xffffffff)
      throw new RangeError(`Invalid material constant ${name}`);
    constants.set(name, value(number));
    source = source.replace(new RegExp(`\\boverride\\s+${name}\\s*:\\s*u32\\s*=\\s*[^;]+;`, 'g'), `const ${name}: u32 = ${number}u;`);
  }
  const parsed = structure(source); let result = '', cursor = 0;
  for (const fn of parsed.functions) {
    const local = new Map(constants);
    // Only these functions consume the root material's flags/layers. Other
    // helpers reuse the same local names for independent texture descriptors.
    const aliases = fn.name === 'vertex_main' ? {flags: 'MATERIAL_FLAGS'}
      : ['shade_material', 'material_alpha', 'environment_coordinate'].includes(fn.name)
        ? {v_flags: 'MATERIAL_FLAGS', v_features: 'MATERIAL_FEATURES', v_layers: 'MATERIAL_LAYERS',
          ...(fn.name === 'shade_material' ? {v_pass: 'SKY_PASS'} : {})} : {};
    const body = parsed.masked.slice(fn.open + 1, fn.close);
    for (const [alias, name] of Object.entries(aliases)) {
      if (!constants.has(name)) continue;
      const declarations = [...body.matchAll(new RegExp(`\\b(?:var|let)\\s+${alias}(?:\\s*:\\s*u32)?\\s*=\\s*([^;]+);`, 'g'))];
      if (declarations.length !== 1) continue;
      const declaration = declarations[0], initializer = declaration[1].replace(/[()\s]/g, '');
      if (initializer !== name && !(fn.name === 'material_alpha' && alias === 'v_flags' && initializer === 'cw_arg_flags')) continue;
      const remaining = body.slice(0, declaration.index) + body.slice(declaration.index + declaration[0].length);
      // Keep unknown values intact if a future WGSL edit mutates an alias or
      // passes its address to a helper. Only immutable root aliases are folded.
      if (new RegExp(`\\b${alias}\\s*(?:(?:>>|<<|[+*/%&|^-])?=(?!=)|\\+\\+|--)|(?:\\+\\+|--|&)\\s*\\b${alias}\\b`).test(remaining)) continue;
      local.set(alias, constants.get(name));
    }
    // v_mode is intentionally excluded: fog mode shadows material mode.
    result += source.slice(cursor, fn.start) + foldFunction(source, parsed, fn, local); cursor = fn.end;
  }
  result += source.slice(cursor);
  const roots = fragmentEntryPoint
    ? ['vertex_main', fragmentEntryPoint]
    : allRoots;
  if (fragmentEntryPoint && !allRoots.includes(fragmentEntryPoint))
    throw new RangeError(`Unknown material fragment entry point ${fragmentEntryPoint}`);
  return pruneFunctions(result, roots);
}
