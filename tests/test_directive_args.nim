## test_directive_args.nim
## Schema-driven coercion of a directive's argument list: labelled and
## positional values, units, defaults, and one diagnostic per way a call can
## be wrong — without ever throwing or partially applying.
##
## Ported from `DirectiveArgumentTests.swift`.

import std/[unittest, sequtils]
import markdownengine
import ./directive_fixtures

let baseSchema = @[
  labeledParam("size", dpLength),
  labeledParam("family", dpString),
  labeledParam("weight", dpKeyword, allowed = @["regular", "bold"],
               defaultValue = dvKeyword("regular"), hasDefault = true),
  labeledParam("wrap", dpBoolean),
  labeledParam("count", dpNumber),
]

proc parse(arguments: string,
           schema: seq[DirectiveParameter] = baseSchema): DirectiveArguments =
  ## Parse the text between the parens of `@x(…)`.
  let t = initText("(" & arguments & ")")
  parseArguments(t, rng(1, t.len - 2), true, schema)

proc hasDiagnostic(a: DirectiveArguments, kind: DirectiveDiagnosticKind,
                   label = ""): bool =
  a.diagnostics.anyIt(it.kind == kind and (label.len == 0 or it.label == label))

suite "directive arguments — labelled values":

  test "labelled values coerce by kind":
    let args = parse("size: 18, family: \"Menlo\", wrap: true, count: 3")
    check args.numberArg("size") == (18.0, true)
    check args.stringArg("family") == ("Menlo", true)
    check args.boolArg("wrap") == (true, true)
    check args.numberArg("count") == (3.0, true)
    check args.isValid

  test "whitespace around labels and values is ignored":
    check parse("  size :  18  ").numberArg("size") == (18.0, true)

  test "an unquoted string value is accepted":
    check parse("family: Menlo").stringArg("family") == ("Menlo", true)

suite "directive arguments — units":

  test "units parse and resolve":
    for (input, raw, resolved) in [("size: 18", 18.0, 18.0),
                                   ("size: 18pt", 18.0, 18.0),
                                   ("size: 1.5em", 1.5, 18.0),
                                   ("size: 50%", 50.0, 6.0)]:
      checkpoint(input)
      let args = parse(input)
      check args.numberArg("size") == (raw, true)
      check args.lengthArg("size", 12.0) == (resolved, true)

suite "directive arguments — positional values":

  test "positional values fill the unlabelled slots in order":
    let schema = @[positionalParam(dpKeyword), positionalParam(dpNumber)]
    let args = parse("red, 3", schema)
    check args.positional.len == 2
    check args.positional[0].asString == ("red", true)
    check args.positional[1].asDouble == (3.0, true)

  test "a surplus positional value is a diagnostic, not a crash":
    let args = parse("red, blue", @[positionalParam(dpKeyword)])
    check args.positional.len == 1
    check args.hasDiagnostic(ddTooManyPositional)

suite "directive arguments — splitting":

  test "a comma inside a quoted value does not split the argument":
    check parse("family: \"Helvetica, Neue\"").stringArg("family") ==
      ("Helvetica, Neue", true)

  test "a colon inside a quoted value is not a label separator":
    check parse("family: \"12:30\"").stringArg("family") == ("12:30", true)

  test "a comma inside nested parens does not split the argument":
    check parse("family: fn(a, b), size: 18").numberArg("size") == (18.0, true)

suite "directive arguments — defaults":

  test "an unsupplied parameter takes its default":
    check parse("size: 18").stringArg("weight") == ("regular", true)

  test "a supplied value beats the default":
    check parse("weight: bold").stringArg("weight") == ("bold", true)

  test "an empty argument list still applies defaults":
    let args = parseArguments(initText(""), Range(), false, baseSchema)
    check args.stringArg("weight") == ("regular", true)

suite "directive arguments — diagnostics":

  test "an unknown label is reported and dropped":
    let args = parse("colour: red")
    check args.hasDiagnostic(ddUnknownLabel, "colour")
    check args.value("colour")[1] == false
    check not args.isValid

  test "a type mismatch is reported and dropped":
    let args = parse("count: notanumber")
    check args.numberArg("count")[1] == false
    check args.hasDiagnostic(ddTypeMismatch, "count")

  test "a keyword outside its closed set is a mismatch":
    let args = parse("weight: heavy")
    # Falls back to the default rather than passing an unsupported value.
    check args.stringArg("weight") == ("regular", true)
    check not args.isValid

  test "a missing required parameter is reported":
    let args = parse("", @[labeledParam("src", dpString, isRequired = true)])
    check args.hasDiagnostic(ddMissingRequired, "src")

  test "a missing required positional is reported":
    check not parse("", @[positionalParam(dpKeyword, isRequired = true)]).isValid

  test "one bad argument does not discard the good ones":
    let args = parse("size: 18, colour: red")
    check args.numberArg("size") == (18.0, true)
    check not args.isValid

suite "directive arguments — end to end":

  test "arguments read off a parsed directive node":
    let t = initText("@font(size: 1.5em, weight: bold){hi}")
    let registry = initDirectiveRegistry(@[sizedDirective()])
    let (match, ok) = matchDirective(t, t.len, 0, registry)
    check ok
    let args = parseArguments(t, match.argumentsRange, match.hasArguments,
                              sizedDirective().syntax.parameters)
    check args.lengthArg("size", 12.0) == (18.0, true)
    check args.stringArg("weight") == ("bold", true)
    check args.isValid

suite "directive arguments — defaults on positional parameters":
  # A positional parameter carrying a default used to yield nothing: the
  # default fill only walked the labelled ones.

  let positionalSchema = @[
    positionalParam(dpKeyword, isRequired = true),
    positionalParam(dpKeyword, defaultValue = dvKeyword("medium"),
                    hasDefault = true),
  ]

  proc argumentsFor(source: string,
                    schema: seq[DirectiveParameter]): DirectiveArguments =
    let t = initText(source)
    let registry = initDirectiveRegistry(@[selfContainedPair()])
    let (match, _) = matchDirective(t, t.len, 0, registry)
    parseArguments(t, match.argumentsRange, match.hasArguments, schema)

  proc positionalString(args: DirectiveArguments, index: int): string =
    if index >= args.positional.len: return ""
    let (s, ok) = args.positional[index].asString
    if ok: s else: ""

  test "an unsupplied positional falls back to its default":
    let args = argumentsFor("@pair(star)", positionalSchema)
    check positionalString(args, 0) == "star"
    check positionalString(args, 1) == "medium"
    check args.isValid

  test "a supplied positional wins over its default":
    let args = argumentsFor("@pair(star, large)", positionalSchema)
    check positionalString(args, 1) == "large"
    check args.isValid

  test "a required positional with no default is still reported missing":
    let args = argumentsFor("@pair", positionalSchema)
    check not args.isValid
    check args.hasDiagnostic(ddMissingRequired, "#0")

  test "a default cannot be skipped over to reach a later parameter":
    # Defaults fill a TAIL. There is no syntax for skipping one, so the first
    # positional without a default stops the fill and is reported instead.
    let schema = @[
      positionalParam(dpKeyword, isRequired = true),
      positionalParam(dpKeyword, defaultValue = dvKeyword("mid"), hasDefault = true),
      positionalParam(dpKeyword, isRequired = true),
    ]
    let args = argumentsFor("@pair(a)", schema)
    check positionalString(args, 1) == "mid"
    check args.hasDiagnostic(ddMissingRequired, "#2")
