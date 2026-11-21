"""Executable serialization tests for the live MT ``order.fill`` payloads.

FinaticCore fails closed when a fill arrives without broker execution
evidence (FinaticBackground#827), so the live MT4/MT5 reference serializers
must emit a broker-derived ``time`` field and must emit syntactically valid
JSON.

These tests do not grep for source markers. They parse the reference EA
sources, execute the live serializer against a simulated terminal and broker,
and parse the rendered payload with :func:`json.loads`.
"""

from __future__ import annotations

import json
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).parents[2]
MT4_SOURCE = (
    REPO_ROOT
    / "src/finatic_mt_connector/ea_reference/mt4/FinaticMT4ConnectorEA.mq4"
)
MT5_SOURCE = (
    REPO_ROOT
    / "src/finatic_mt_connector/ea_reference/mt5/FinaticMT5ConnectorEA.mq5"
)

BROKER_DEAL_TIME = datetime(2026, 11, 20, 12, 20, 55, tzinfo=UTC)
BROKER_DEAL_TIME_TEXT = "2026.11.20 12:20:55"
TERMINAL_CLOCK = BROKER_DEAL_TIME + timedelta(seconds=5)
TERMINAL_CLOCK_TEXT = "2026.11.20 12:21:00"

DEAL_TICKET = 101
ORDER_TICKET = 101
LOGIN = 1001
SYMBOL = "EURUSD"
VOLUME = 1.0
PRICE = 123.0
SIDE = "buy"

# --- MQL constants used by the executed serializers -------------------------
MQL_CONSTANTS: dict[str, int] = {
    "TRADE_TRANSACTION_DEAL_ADD": 1,
    "TRADE_TRANSACTION_ORDER_ADD": 0,
    "TRADE_TRANSACTION_ORDER_UPDATE": 2,
    "TRADE_TRANSACTION_ORDER_DELETE": 3,
    "ORDER_TYPE_BUY": 0,
    "ORDER_TYPE_SELL": 1,
    "ORDER_TYPE_BUY_LIMIT": 2,
    "ORDER_TYPE_SELL_LIMIT": 3,
    "ORDER_TYPE_BUY_STOP": 4,
    "ORDER_TYPE_SELL_STOP": 5,
    "ORDER_TYPE_BUY_STOP_LIMIT": 6,
    "ORDER_TYPE_SELL_STOP_LIMIT": 7,
    "OP_BUY": 0,
    "OP_SELL": 1,
    "OP_BUYLIMIT": 2,
    "OP_SELLLIMIT": 3,
    "OP_BUYSTOP": 4,
    "OP_SELLSTOP": 5,
    "DEAL_TICKET": 1,
    "DEAL_ORDER": 2,
    "DEAL_TIME": 3,
    "DEAL_TIME_MSC": 4,
    "DEAL_TYPE": 5,
    "TIME_DATE": 1,
    "TIME_SECONDS": 2,
    "ACCOUNT_LOGIN": 0,
    "SELECT_BY_POS": 0,
    "MODE_TRADES": 0,
}

_TYPE_KEYWORDS = {
    "void",
    "int",
    "long",
    "double",
    "float",
    "string",
    "bool",
    "datetime",
    "ulong",
    "uint",
    "short",
    "char",
    "color",
}

_TOKEN_PATTERN = re.compile(
    r"(?P<number>0[xX][0-9a-fA-F]+|\d+\.\d*|\.\d+|\d+)"
    r"|(?P<identifier>[A-Za-z_]\w*)"
    r"|(?P<operator><=|>=|==|!=|&&|\|\||[-+*/%<>=!()\[\]{},;:.&|?^])"
)

_STRING_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    '"': '"',
    "\\": "\\",
    "'": "'",
    "0": "\0",
}


# ---------------------------------------------------------------------------
# MQL source tokenizer
# ---------------------------------------------------------------------------
def _scan_string_literal(source: str, start: int) -> int:
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
            continue
        if source[index] == '"':
            return index + 1
        index += 1
    raise AssertionError("unterminated MQL string literal")


def _scan_char_literal(source: str, start: int) -> int:
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
            continue
        if source[index] == "'":
            return index + 1
        index += 1
    raise AssertionError("unterminated MQL character literal")


def _tokenize(source: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    index = 0
    length = len(source)
    while index < length:
        character = source[index]
        if character.isspace():
            index += 1
            continue
        if character == "#":
            newline = source.find("\n", index)
            index = length if newline < 0 else newline + 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index)
            index = length if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            index = length if closing < 0 else closing + 2
            continue
        if character == '"':
            end = _scan_string_literal(source, index)
            tokens.append(("string", source[index:end]))
            index = end
            continue
        if character == "'":
            end = _scan_char_literal(source, index)
            tokens.append(("char", source[index:end]))
            index = end
            continue
        match = _TOKEN_PATTERN.match(source, index)
        if match is None:
            raise AssertionError(
                f"unsupported MQL source at offset {index}: {source[index : index + 24]!r}"
            )
        kind = match.lastgroup or "operator"
        tokens.append((kind, match.group()))
        index = match.end()
    return tokens


def _decode_mql_string(literal: str) -> str:
    body = literal[1:-1]
    decoded: list[str] = []
    index = 0
    while index < len(body):
        character = body[index]
        if character == "\\" and index + 1 < len(body):
            following = body[index + 1]
            if following in _STRING_ESCAPES:
                decoded.append(_STRING_ESCAPES[following])
                index += 2
                continue
            decoded.append(following)
            index += 2
            continue
        decoded.append(character)
        index += 1
    return "".join(decoded)


# ---------------------------------------------------------------------------
# MQL source parser (statements and expressions used by the EA references)
# ---------------------------------------------------------------------------
_BINARY_LEVELS: tuple[tuple[str, ...], ...] = (
    ("||",),
    ("&&",),
    ("==", "!="),
    ("<", "<=", ">", ">="),
    ("|",),
    ("^",),
    ("+", "-"),
    ("*", "/", "%"),
)


class _Parser:
    """Recursive-descent parser for the MQL subset used by the EAs."""

    def __init__(
        self, tokens: list[tuple[str, str]], position: int = 0
    ) -> None:
        self._tokens = tokens
        self._position = position

    # -- token helpers ------------------------------------------------------
    def at_end(self) -> bool:
        return self._position >= len(self._tokens)

    def peek(self, offset: int = 0) -> tuple[str, str]:
        index = self._position + offset
        if index >= len(self._tokens):
            return ("end", "")
        return self._tokens[index]

    def advance(self) -> tuple[str, str]:
        token = self.peek()
        self._position += 1
        return token

    def at(self, value: str) -> bool:
        return self.peek()[1] == value

    def expect(self, value: str) -> tuple[str, str]:
        token = self.advance()
        if token[1] != value:
            raise AssertionError(f"expected {value!r} but found {token[1]!r}")
        return token

    # -- program ------------------------------------------------------------
    def parse_params(self) -> list[tuple[str, str, bool]]:
        self.expect("(")
        params: list[tuple[str, str, bool]] = []
        while not self.at(")"):
            if self.at(","):
                self.advance()
                continue
            collected: list[str] = []
            is_reference = False
            while not self.at(",") and not self.at(")"):
                token = self.advance()
                if token[1] == "&":
                    is_reference = True
                    continue
                collected.append(token[1])
            if not collected:
                continue
            type_name = collected[-2] if len(collected) > 1 else "auto"
            params.append((collected[-1], type_name, is_reference))
        self.expect(")")
        return params

    def parse_block(self) -> list[Any]:
        self.expect("{")
        statements: list[Any] = []
        while not self.at("}"):
            if self.at_end():
                raise AssertionError("unterminated MQL block")
            statements.append(self.parse_statement())
        self.expect("}")
        return statements

    def parse_statement(self) -> Any:
        token = self.peek()
        if token[1] == "{":
            return ("block", self.parse_block())
        if token[1] == "if":
            self.advance()
            self.expect("(")
            condition = self.parse_expression()
            self.expect(")")
            then_branch = self.parse_statement()
            else_branch = None
            if self.at("else"):
                self.advance()
                else_branch = self.parse_statement()
            return ("if", condition, then_branch, else_branch)
        if token[1] == "return":
            self.advance()
            if self.at(";"):
                self.advance()
                return ("return", None)
            value = self.parse_expression()
            self.expect(";")
            return ("return", value)
        if token[1] in ("for", "while", "switch"):
            raise AssertionError(f"unsupported MQL statement: {token[1]}")
        if (
            token[0] == "identifier"
            and token[1] == "Print"
            and self.peek(1)[1] == "("
        ):
            self.advance()
            arguments = self.parse_arguments()
            self.expect(";")
            return ("print", arguments)
        if (
            token[0] == "identifier"
            and token[1] in _TYPE_KEYWORDS
            and self.peek(1)[0] == "identifier"
        ):
            type_name = self.advance()[1]
            name = self.advance()[1]
            if self.at("="):
                self.advance()
                value = self.parse_expression()
                self.expect(";")
                return ("decl", type_name, name, value)
            self.expect(";")
            return ("decl", type_name, name, None)
        expression = self.parse_expression()
        if self.at("="):
            self.advance()
            value = self.parse_expression()
            self.expect(";")
            return ("assign", expression, value)
        self.expect(";")
        return ("expr", expression)

    # -- expressions --------------------------------------------------------
    def parse_expression(self) -> Any:
        return self.parse_ternary()

    def parse_ternary(self) -> Any:
        condition = self.parse_binary(0)
        if self.at("?"):
            self.advance()
            then_expression = self.parse_expression()
            self.expect(":")
            else_expression = self.parse_ternary()
            return ("ternary", condition, then_expression, else_expression)
        return condition

    def parse_binary(self, level: int) -> Any:
        if level >= len(_BINARY_LEVELS):
            return self.parse_unary()
        left = self.parse_binary(level + 1)
        while self.peek()[1] in _BINARY_LEVELS[level]:
            operator = self.advance()[1]
            right = self.parse_binary(level + 1)
            left = ("binary", operator, left, right)
        return left

    def parse_unary(self) -> Any:
        token = self.peek()
        if token[1] in ("!", "-", "+"):
            self.advance()
            return ("unary", token[1], self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self) -> Any:
        expression = self.parse_primary()
        while True:
            if self.at("."):
                self.advance()
                name = self.advance()[1]
                expression = ("member", expression, name)
                continue
            if self.at("("):
                arguments = self.parse_arguments()
                expression = ("call", expression, arguments)
                continue
            break
        return expression

    def parse_arguments(self) -> list[Any]:
        self.expect("(")
        arguments: list[Any] = []
        while not self.at(")"):
            if self.at(","):
                self.advance()
                continue
            arguments.append(self.parse_expression())
        self.expect(")")
        return arguments

    def parse_primary(self) -> Any:
        token = self.peek()
        if token[1] == "(":
            if (
                self.peek(1)[0] == "identifier"
                and self.peek(1)[1] in _TYPE_KEYWORDS
                and self.peek(2)[1] == ")"
            ):
                type_name = self.advance()[1]
                self.advance()
                self.advance()
                return ("cast", type_name, self.parse_unary())
            self.advance()
            expression = self.parse_expression()
            self.expect(")")
            return expression
        if token[0] == "string":
            self.advance()
            return ("str", _decode_mql_string(token[1]))
        if token[0] == "char":
            self.advance()
            return ("num", ord(_decode_mql_string(token[1][1:-1])[0]))
        if token[0] == "number":
            self.advance()
            if token[1].lower().startswith("0x"):
                return ("num", int(token[1], 16))
            if "." in token[1]:
                return ("num", float(token[1]))
            return ("num", int(token[1]))
        if token[0] == "identifier":
            self.advance()
            if token[1] == "true":
                return ("num", True)
            if token[1] == "false":
                return ("num", False)
            return ("name", token[1])
        raise AssertionError(f"unsupported MQL token: {token}")


def _index_functions(
    tokens: list[tuple[str, str]],
) -> dict[str, tuple[int, int]]:
    """Map function name to (signature start, body start) token offsets."""
    index: dict[str, tuple[int, int]] = {}
    depth = 0
    position = 0
    while position < len(tokens):
        value = tokens[position][1]
        if value == "{":
            depth += 1
            position += 1
            continue
        if value == "}":
            depth -= 1
            position += 1
            continue
        if (
            depth == 0
            and tokens[position][0] == "identifier"
            and value in _TYPE_KEYWORDS
            and position + 2 < len(tokens)
            and tokens[position + 1][0] == "identifier"
            and tokens[position + 2][1] == "("
        ):
            name = tokens[position + 1][1]
            cursor = position + 2
            level = 0
            while cursor < len(tokens):
                if tokens[cursor][1] == "(":
                    level += 1
                elif tokens[cursor][1] == ")":
                    level -= 1
                    if level == 0:
                        break
                cursor += 1
            if cursor + 1 < len(tokens) and tokens[cursor + 1][1] == "{":
                index[name] = (position, cursor + 1)
                position = cursor + 1
                continue
        position += 1
    return index


class _Program:
    """Lazily parsed view over an MQL source file."""

    def __init__(self, source: str) -> None:
        self._tokens = _tokenize(source)
        self._index = _index_functions(self._tokens)
        self._cache: dict[
            str, tuple[list[tuple[str, str, bool]], list[Any]]
        ] = {}

    def function(
        self, name: str
    ) -> tuple[list[tuple[str, str, bool]], list[Any]]:
        if name in self._cache:
            return self._cache[name]
        if name not in self._index:
            raise AssertionError(
                f"MQL function {name!r} was not found in the source"
            )
        start, _ = self._index[name]
        parser = _Parser(self._tokens, start)
        parser.advance()
        parser.advance()
        params = parser.parse_params()
        body = parser.parse_block()
        self._cache[name] = (params, body)
        return self._cache[name]


# ---------------------------------------------------------------------------
# MQL evaluator
# ---------------------------------------------------------------------------
class _ReturnError(Exception):
    def __init__(self, value: Any) -> None:
        super().__init__("return")
        self.value = value


class _Reference:
    """A by-reference parameter binding."""

    def __init__(self, scope: _Scope, name: str) -> None:
        self.scope = scope
        self.name = name

    def read(self) -> Any:
        owner = self.scope.owner(self.name)
        if owner is None:
            return None
        return owner.values.get(self.name)

    def write(self, value: Any) -> None:
        owner = self.scope.owner(self.name)
        if owner is None:
            return
        current = owner.values.get(self.name)
        if isinstance(current, _Reference):
            current.write(value)
            return
        owner.values[self.name] = value


class _Scope:
    def __init__(self, parent: _Scope | None = None) -> None:
        self.values: dict[str, Any] = {}
        self.parent = parent

    def owner(self, name: str) -> _Scope | None:
        scope: _Scope | None = self
        while scope is not None:
            if name in scope.values:
                return scope
            scope = scope.parent
        return None

    def read(self, name: str) -> Any:
        owner = self.owner(name)
        if owner is None:
            raise KeyError(name)
        value = owner.values[name]
        if isinstance(value, _Reference):
            return value.read()
        return value

    def write(self, name: str, value: Any) -> None:
        owner = self.owner(name)
        if owner is None:
            self.values[name] = value
            return
        current = owner.values[name]
        if isinstance(current, _Reference):
            current.write(value)
            return
        owner.values[name] = value


def _mql_truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return len(value) > 0
    return bool(value)


def _mql_text(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return repr(value)
    return str(value)


def _mql_add(left: Any, right: Any) -> Any:
    if isinstance(left, str) or isinstance(right, str):
        return _mql_text(left) + _mql_text(right)
    return left + right


class _Runtime:
    """Executes parsed MQL functions against a simulated terminal/broker."""

    def __init__(self, program: _Program, builtins: dict[str, Any]) -> None:
        self._program = program
        self._builtins = builtins
        self.global_scope = _Scope()

    def call(
        self,
        name: str,
        arguments: list[Any],
        caller_scope: _Scope | None = None,
    ) -> Any:
        params, body = self._program.function(name)
        scope = _Scope(self.global_scope)
        references = caller_scope or self.global_scope
        for (param_name, _type_name, is_reference), argument in zip(
            params, arguments, strict=True
        ):
            if (
                is_reference
                and isinstance(argument, tuple)
                and argument[0] == "ref"
            ):
                scope.values[param_name] = _Reference(references, argument[1])
                continue
            scope.values[param_name] = argument
        try:
            self._execute(body, scope)
        except _ReturnError as returned:
            return returned.value
        return None

    # -- statements ---------------------------------------------------------
    def _execute(self, statements: list[Any], scope: _Scope) -> None:
        for statement in statements:
            self._execute_statement(statement, scope)

    def _execute_statement(self, statement: Any, scope: _Scope) -> None:
        kind = statement[0]
        if kind == "block":
            self._execute(statement[1], scope)
            return
        if kind == "decl":
            _type_name, name, value = statement[1], statement[2], statement[3]
            scope.values[name] = (
                None if value is None else self._evaluate(value, scope)
            )
            return
        if kind == "assign":
            self._assign(statement[1], statement[2], scope)
            return
        if kind == "expr":
            self._evaluate(statement[1], scope)
            return
        if kind == "print":
            rendered = " ".join(
                _mql_text(self._evaluate(argument, scope))
                for argument in statement[1]
            )
            self._builtins["Print"](rendered)
            return
        if kind == "if":
            condition = self._evaluate(statement[1], scope)
            if _mql_truthy(condition):
                self._execute_statement(statement[2], scope)
            elif statement[3] is not None:
                self._execute_statement(statement[3], scope)
            return
        if kind == "return":
            value = (
                None
                if statement[1] is None
                else self._evaluate(statement[1], scope)
            )
            raise _ReturnError(value)
        raise AssertionError(f"unsupported MQL statement: {kind}")

    def _assign(
        self, target: Any, value_expression: Any, scope: _Scope
    ) -> None:
        value = self._evaluate(value_expression, scope)
        if target[0] == "name":
            scope.write(target[1], value)
            return
        if target[0] == "member":
            owner = self._evaluate(target[1], scope)
            owner[target[2]] = value
            return
        raise AssertionError("unsupported MQL assignment target")

    # -- expressions --------------------------------------------------------
    def _evaluate(self, expression: Any, scope: _Scope) -> Any:
        kind = expression[0]
        if kind == "num":
            return expression[1]
        if kind == "str":
            return expression[1]
        if kind == "name":
            name = expression[1]
            owner = scope.owner(name)
            if owner is None:
                if name in MQL_CONSTANTS:
                    return MQL_CONSTANTS[name]
                if name in self._builtins:
                    return self._builtins[name]
                raise AssertionError(f"unknown MQL identifier: {name}")
            value = owner.values[name]
            if isinstance(value, _Reference):
                return value.read()
            return value
        if kind == "member":
            owner = self._evaluate(expression[1], scope)
            attribute = expression[2]
            if isinstance(owner, dict):
                if attribute not in owner:
                    raise AssertionError(
                        f"unknown MQL member {attribute!r} on {owner!r}"
                    )
                return owner[attribute]
            raise AssertionError(f"unsupported MQL member access on {owner!r}")
        if kind == "call":
            callee = expression[1]
            if callee[0] != "name":
                raise AssertionError("unsupported MQL call target")
            name = callee[1]
            if name in self._builtins:
                arguments = [
                    self._evaluate(argument, scope)
                    for argument in expression[2]
                ]
                return self._builtins[name](*arguments)
            arguments = []
            params, _body = self._program.function(name)
            for index, argument in enumerate(expression[2]):
                is_reference = index < len(params) and params[index][2]
                if (
                    is_reference
                    and argument[0] == "name"
                    and scope.owner(argument[1]) is not None
                ):
                    arguments.append(("ref", argument[1]))
                    continue
                arguments.append(self._evaluate(argument, scope))
            return self.call(name, arguments, scope)
        if kind == "unary":
            operand = self._evaluate(expression[2], scope)
            if expression[1] == "!":
                return not _mql_truthy(operand)
            if expression[1] == "-":
                return -operand
            return operand
        if kind == "binary":
            return self._evaluate_binary(expression, scope)
        if kind == "ternary":
            condition = self._evaluate(expression[1], scope)
            if _mql_truthy(condition):
                return self._evaluate(expression[2], scope)
            return self._evaluate(expression[3], scope)
        if kind == "cast":
            return self._evaluate_cast(expression[1], expression[2], scope)
        raise AssertionError(f"unsupported MQL expression: {kind}")

    def _evaluate_binary(self, expression: Any, scope: _Scope) -> Any:
        operator = expression[1]
        left = self._evaluate(expression[2], scope)
        if operator == "&&":
            if not _mql_truthy(left):
                return False
            return _mql_truthy(self._evaluate(expression[3], scope))
        if operator == "||":
            if _mql_truthy(left):
                return True
            return _mql_truthy(self._evaluate(expression[3], scope))
        right = self._evaluate(expression[3], scope)
        if operator == "+":
            return _mql_add(left, right)
        if operator == "-":
            return left - right
        if operator == "*":
            return left * right
        if operator == "/":
            if isinstance(left, int) and isinstance(right, int):
                return int(left / right)
            return left / right
        if operator == "%":
            return int(left) % int(right)
        if operator == "|":
            return int(left) | int(right)
        if operator == "^":
            return int(left) ^ int(right)
        if operator == "==":
            return left == right
        if operator == "!=":
            return left != right
        if operator == "<":
            return left < right
        if operator == "<=":
            return left <= right
        if operator == ">":
            return left > right
        if operator == ">=":
            return left >= right
        raise AssertionError(f"unsupported MQL operator: {operator}")

    def _evaluate_cast(
        self, type_name: str, expression: Any, scope: _Scope
    ) -> Any:
        value = self._evaluate(expression, scope)
        if type_name in ("long", "int", "short", "char", "uint", "ulong"):
            return int(value)
        if type_name in ("double", "float"):
            return float(value)
        if type_name == "datetime":
            return int(value)
        if type_name == "string":
            return _mql_text(value)
        if type_name == "bool":
            return _mql_truthy(value)
        return value


# ---------------------------------------------------------------------------
# Simulated MT4 / MT5 terminal and broker
# ---------------------------------------------------------------------------
def _mql_time_text(seconds: int) -> str:
    return datetime.fromtimestamp(seconds, tz=UTC).strftime("%Y.%m.%d %H:%M:%S")


def _common_builtins(
    logs: list[str],
    *,
    server_now: int,
    gmt_now: int,
    local_now: int,
) -> dict[str, Any]:
    def _print(message: str) -> None:
        logs.append(message)

    return {
        "Print": _print,
        "IntegerToString": lambda value: str(int(value)),
        "DoubleToString": lambda value, digits=8: (
            f"{float(value):.{int(digits)}f}"
        ),
        "TimeToString": lambda value, flags=0: _mql_time_text(int(value)),
        "TimeCurrent": lambda: server_now,
        "TimeGMT": lambda: gmt_now,
        "TimeLocal": lambda: local_now,
        "StringLen": lambda value: len(value),
        "StringFind": lambda value, needle, start=0: value.find(needle, start),
        "StringSubstr": lambda value, start, count=None: (
            value[start:] if count is None else value[start : start + count]
        ),
        "StringReplace": lambda value, needle, replacement: value.replace(
            needle, replacement
        ),
        "StringGetCharacter": lambda value, position: ord(value[position]),
    }


class _Mt5Broker:
    """Simulated MT5 broker history used by the live MT5 serializer."""

    def __init__(
        self,
        *,
        deal_time_seconds: int | None = None,
        deal_time_millis: int | None = None,
        history_select_ok: bool = True,
        deal_select_ok: bool = True,
    ) -> None:
        self.deal_time_seconds = (
            int(BROKER_DEAL_TIME.timestamp())
            if deal_time_seconds is None
            else deal_time_seconds
        )
        self.deal_time_millis = (
            int(BROKER_DEAL_TIME.timestamp() * 1000)
            if deal_time_millis is None
            else deal_time_millis
        )
        self.history_select_ok = history_select_ok
        self.deal_select_ok = deal_select_ok
        self.history_select_calls: list[tuple[int, int]] = []
        self.deal_select_calls: list[int] = []
        self.deal_integer_reads: list[tuple[int, int]] = []

    def builtins(self, logs: list[str]) -> dict[str, Any]:
        broker = self

        def _history_select(from_time: int, to_time: int) -> bool:
            broker.history_select_calls.append((int(from_time), int(to_time)))
            return broker.history_select_ok

        def _deal_select(ticket: int) -> bool:
            broker.deal_select_calls.append(int(ticket))
            return broker.deal_select_ok

        def _deal_get_integer(ticket: int, prop: int) -> int:
            broker.deal_integer_reads.append((int(ticket), int(prop)))
            if int(prop) == MQL_CONSTANTS["DEAL_TIME"]:
                return broker.deal_time_seconds
            if int(prop) == MQL_CONSTANTS["DEAL_TIME_MSC"]:
                return broker.deal_time_millis
            if int(prop) == MQL_CONSTANTS["DEAL_ORDER"]:
                return ORDER_TICKET
            return 0

        builtins = _common_builtins(
            logs,
            server_now=int(TERMINAL_CLOCK.timestamp()),
            gmt_now=int(TERMINAL_CLOCK.timestamp()) + 1,
            local_now=int(TERMINAL_CLOCK.timestamp()) + 2,
        )
        builtins.update(
            {
                "AccountInfoInteger": lambda prop: LOGIN,
                "AccountInfoString": lambda prop: "USD",
                "AccountInfoDouble": lambda prop: 10_000.0,
                "HistorySelect": _history_select,
                "HistoryDealSelect": _deal_select,
                "HistoryDealGetInteger": _deal_get_integer,
                "HistoryDealGetString": lambda ticket, prop: SYMBOL,
                "HistoryDealGetDouble": lambda ticket, prop: PRICE,
            }
        )
        return builtins


class _Mt4Terminal:
    """Simulated MT4 terminal order state used by the live MT4 serializer."""

    def __init__(self, *, order_open_time: int | None = None) -> None:
        self.order_open_time = (
            int(BROKER_DEAL_TIME.timestamp())
            if order_open_time is None
            else order_open_time
        )
        self.select_calls: list[tuple[int, int, int]] = []

    def builtins(self, logs: list[str]) -> dict[str, Any]:
        terminal = self

        def _order_select(position: int, select_type: int, mode: int) -> bool:
            terminal.select_calls.append(
                (int(position), int(select_type), int(mode))
            )
            return True

        builtins = _common_builtins(
            logs,
            server_now=int(TERMINAL_CLOCK.timestamp()),
            gmt_now=int(TERMINAL_CLOCK.timestamp()) + 1,
            local_now=int(TERMINAL_CLOCK.timestamp()) + 2,
        )
        builtins.update(
            {
                "AccountNumber": lambda: LOGIN,
                "AccountCurrency": lambda: "USD",
                "OrdersTotal": lambda: 1,
                "OrderSelect": _order_select,
                "OrderTicket": lambda: ORDER_TICKET,
                "OrderType": lambda: MQL_CONSTANTS["OP_BUY"],
                "OrderSymbol": lambda: SYMBOL,
                "OrderLots": lambda: VOLUME,
                "OrderOpenPrice": lambda: PRICE,
                "OrderOpenTime": lambda: terminal.order_open_time,
                "OrderStopLoss": lambda: 0.0,
                "OrderTakeProfit": lambda: 0.0,
            }
        )
        return builtins


def _mt5_transaction() -> dict[str, Any]:
    """Simulated MqlTradeTransaction for a filled market buy."""
    return {
        "type": MQL_CONSTANTS["TRADE_TRANSACTION_DEAL_ADD"],
        "deal": DEAL_TICKET,
        "order": ORDER_TICKET,
        "symbol": SYMBOL,
        "volume": VOLUME,
        "price": PRICE,
        "order_type": MQL_CONSTANTS["ORDER_TYPE_BUY"],
    }


def _render_mt5_fill(broker: _Mt5Broker) -> tuple[str, list[str]]:
    logs: list[str] = []
    program = _Program(MT5_SOURCE.read_text(encoding="utf-8"))
    runtime = _Runtime(program, broker.builtins(logs))
    payload = runtime.call(
        "finaticBuildTransactionEventJson", [_mt5_transaction()]
    )
    return str(payload), logs


def _render_mt4_fill(terminal: _Mt4Terminal) -> tuple[str, list[str]]:
    logs: list[str] = []
    program = _Program(MT4_SOURCE.read_text(encoding="utf-8"))
    runtime = _Runtime(program, terminal.builtins(logs))
    payload = runtime.call("finaticBuildTradeEventJson", [])
    return str(payload), logs


def _extract_live_fill_serializer(source: str) -> str:
    """Return the live ``order.fill`` serializer block from an EA source."""
    marker = r"event_type\":\"order.fill"
    marker_index = source.index(marker)
    start = source.rindex("return(", 0, marker_index)
    end = source.index(");", marker_index)
    return source[start:end]


# ---------------------------------------------------------------------------
# Tests: live fill payloads render valid JSON with broker execution time
# ---------------------------------------------------------------------------
def test_mt5_live_fill_payload_is_valid_json_with_broker_execution_time() -> (
    None
):
    broker = _Mt5Broker()
    payload, logs = _render_mt5_fill(broker)

    assert payload, logs
    parsed = json.loads(payload)

    assert parsed["event_type"] == "order.fill"
    fill = parsed["payload"]
    assert fill["deal_id"] == str(DEAL_TICKET)
    assert fill["order_id"] == str(ORDER_TICKET)
    assert fill["symbol"] == SYMBOL
    assert fill["volume"] == VOLUME
    assert fill["price"] == PRICE
    assert fill["side"] == SIDE
    assert fill["time"] == BROKER_DEAL_TIME_TEXT
    assert fill["login"] == str(LOGIN)


def test_mt4_live_fill_payload_is_valid_json_with_broker_execution_time() -> (
    None
):
    terminal = _Mt4Terminal()
    payload, logs = _render_mt4_fill(terminal)

    assert payload, logs
    parsed = json.loads(payload)

    assert parsed["event_type"] == "order.fill"
    fill = parsed["payload"]
    assert fill["deal_id"] == str(ORDER_TICKET)
    assert fill["order_id"] == str(ORDER_TICKET)
    assert fill["symbol"] == SYMBOL
    assert fill["volume"] == VOLUME
    assert fill["price"] == PRICE
    assert fill["side"] == SIDE
    assert fill["time"] == BROKER_DEAL_TIME_TEXT
    assert fill["login"] == str(LOGIN)


def test_mt5_fill_time_is_read_from_broker_deal_history() -> None:
    broker = _Mt5Broker()
    payload, _logs = _render_mt5_fill(broker)

    assert DEAL_TICKET in broker.deal_select_calls
    assert (
        DEAL_TICKET,
        MQL_CONSTANTS["DEAL_TIME"],
    ) in broker.deal_integer_reads
    assert (
        DEAL_TICKET,
        MQL_CONSTANTS["DEAL_TIME_MSC"],
    ) in broker.deal_integer_reads

    fill = json.loads(payload)["payload"]
    assert fill["time"] == BROKER_DEAL_TIME_TEXT
    assert fill["time"] != TERMINAL_CLOCK_TEXT


def test_mt4_fill_time_is_read_from_broker_order_open_time() -> None:
    terminal = _Mt4Terminal()
    payload, _logs = _render_mt4_fill(terminal)

    fill = json.loads(payload)["payload"]
    assert fill["time"] == BROKER_DEAL_TIME_TEXT
    assert fill["time"] != TERMINAL_CLOCK_TEXT


def test_mt5_source_has_no_invalid_transaction_time_member() -> None:
    source = MT5_SOURCE.read_text(encoding="utf-8")

    assert "trans.time" not in source


def test_live_fill_serializers_do_not_use_a_terminal_clock() -> None:
    for source_path in (MT4_SOURCE, MT5_SOURCE):
        source = source_path.read_text(encoding="utf-8")
        serializer = _extract_live_fill_serializer(source)
        assert "TimeCurrent(" not in serializer
        assert "TimeGMT(" not in serializer
        assert "TimeLocal(" not in serializer


def test_mt5_fill_is_suppressed_when_broker_time_is_unavailable() -> None:
    scenarios = {
        "history selection failed": _Mt5Broker(history_select_ok=False),
        "deal not selectable": _Mt5Broker(deal_select_ok=False),
        "deal execution time empty": _Mt5Broker(
            deal_time_seconds=0, deal_time_millis=0
        ),
    }
    for label, broker in scenarios.items():
        payload, logs = _render_mt5_fill(broker)

        assert payload == "", label
        assert logs, label
        assert any("Finatic" in message for message in logs), label


def test_mt4_fill_is_suppressed_when_broker_time_is_unavailable() -> None:
    terminal = _Mt4Terminal(order_open_time=0)
    payload, logs = _render_mt4_fill(terminal)

    assert payload == ""
    assert logs
    assert any("Finatic" in message for message in logs)
