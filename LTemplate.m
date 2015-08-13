(* Mathematica Package *)
(* Created by http://wlplugin.halirutan.de/ *)

(* :Title: LTemplate     *)
(* :Context: LTemplate`  *)
(* :Author: szhorvat     *)
(* :Date: 2015-08-03       *)

(* :Package Version: 0.1 *)
(* :Mathematica Version: *)
(* :Copyright: (c) 2015 Szabolcs Horvát *)
(* :Keywords: LibraryLink, C++, Template *)
(* :Discussion: *)

BeginPackage["LTemplate`", {"SymbolicC`", "CCodeGenerator`", "CCompilerDriver`"}]

LTemplate::usage = "LTemplate[name, {LClass[\[Ellipsis]], LClass[\[Ellipsis]], \[Ellipsis]}] represents a library template.";
LClass::usage = "LClass[name, {fun1, fun2, \[Ellipsis]}] represents a class within a template.";
LFun::usage = "LFun[name, {arg1, arg2, \[Ellipsis]}, ret] represents a class member function with the given name, argument types and return type.";

TranslateTemplate::usage = "TranslateTemplate[template] translates the template into C++ code.";
LoadTemplate::usage = "LoadTemplate[template] loads the library defined by the template. The library must already be compiled.";
UnloadTemplate::usage = "UnloadTemplate[template] attempts to unload the library defined by the template.";
CompileTemplate::usage = "CompileTemplate[template] compiles the library defined by the template. Required source files must be present in the current directory.";

FormatTemplate::usage = "FormatTemplate[template] formats the template in an easy to read way.";

ValidTemplateQ::usage = "ValidTemplateQ[template] returns True if the template syntax is valid.";

Make::usage = "Make[class] creates an instance of class.";


Begin["`Private`"] (* Begin Private Context *)

(* Set up package global variables *)

$packageDirectory = DirectoryName[$InputFileName];
$includeDirectory = $packageDirectory;

(* Mathematica version checks *)

minVersion = {10.0, 0};
maxVersion = {10.2, 0};
version    = {$VersionNumber, $ReleaseNumber}
versionString[{major_, minor_}] := StringJoin[ToString /@ {NumberForm[major, {Infinity, 1}], ".", minor}]

If[Not@OrderedQ[{minVersion, version}],
  Print["LTemplate requires at least Mathematica version " <> versionString[minVersion] <> ".  Aborting."];
  Abort[];
]

(* We need to rely on implementation details of SymbolicC, so warn users of yet untested new Mathematica versions. *)
If[Not@OrderedQ[{version, maxVersion}],
  Print[
    StringTemplate[
      "WARNING: LTemplate has not yet been tested with Mathematica ``.\n" <>
      "The latest supported Mathematica version is ``.\n" <>
      "Please report any issues you find."
    ][versionString[version], versionString[maxVersion]]
  ]
]


LibraryFunction::noinst = "Managed library expression instance does not exist.";

LTemplate::info    = "``";
LTemplate::warning = "``";
LTemplate::error   = "``";

(***************** SymbolicC extensions *******************)

(* CDeclareAssign[type, var, value] represents   type var = value;   *)

SymbolicC`Private`IsCExpression[ _CDeclareAssign ] := True

GenerateCode[CDeclareAssign[typeArg_, idArg_, rhs_], opts : OptionsPattern[]] :=
    Module[{type, id},
      type = Flatten[{typeArg}];
      id = Flatten[{idArg}];
      type = Riffle[ Map[ GenerateCode[#, opts] &, type], " "];
      id = Riffle[ Map[ GenerateCode[#, opts] &, id], ", "];
      GenerateCode[CAssign[type <> " " <> id, rhs], opts]
    ]

(* CInlineCode["some code"] will prevent semicolons from being added at the end of "some code" when used in a list *)

GenerateCode[CInlineCode[arg_], opts : OptionsPattern[]] := GenerateCode[arg, opts]

(* CTryCatch[tryCode, catchArg, catchCode] represents try { tryCode } catch (catchArg) { catchCode } *)

GenerateCode[ CTryCatch[try_, arg_, catch_] , opts: OptionsPattern[]] :=
  Module[{},
    "try " <> GenerateCode[CBlock[try], opts] <> "\n" <>
    "catch (" <> SymbolicC`Private`formatArgument[arg, opts] <> ")\n" <>
    GenerateCode[CBlock[catch], opts]
  ]


(****************** Generic template processing ****************)

(*
 Normalizing a template will:
  - Wrap a bare LClass with LTemplate.  This way a bare LClass can be used as a shorter notation for a single-class template.
  - Convert type names to a canonical form
*)

normalizeTypesRules = Dispatch@{
  Verbatim[_Integer] -> Integer,
  Verbatim[_Real] -> Real,
  Verbatim[_Complex] -> Complex,
  Verbatim[True|False] -> "Boolean",
  Verbatim[False|True] -> "Boolean"
};

normalizeTemplate[c : LClass[name_, funs_]] := normalizeTemplate[LTemplate[name, {c}]]
normalizeTemplate[t : LTemplate[name_, classes_]] := t /. normalizeTypesRules
normalizeTemplate[t_] := t


ValidTemplateQ::template = "`` is not a valid template. Templates must follow the syntax LTemplate[name, {class1, class2, \[Ellipsis]}].";
ValidTemplateQ::class    = "In ``: `` is not a valid class. Classes must follow the syntax LClass[name, {fun1, fun2, \[Ellipsis]}.";
ValidTemplateQ::fun      = "In ``: `` is not a valid function. Functions must follow the syntax LFun[name, {arg1, arg2, \[Ellipsis]}, ret].";
ValidTemplateQ::string   = "In ``: String expected instead of ``";
ValidTemplateQ::name     = "In ``: `` is not a valid name. Names must start with a letter and may only contain letters and digits.";
ValidTemplateQ::type     = "In ``: `` is not a valid type.";
ValidTemplateQ::dupclass = "In ``: Class `` appears more than once.";
ValidTemplateQ::dupfun   = "In ``: Function `` appears more than once.";

ValidTemplateQ[tem_] := validateTemplate@normalizeTemplate[tem]


validateTemplate[tem_] := (Message[ValidTemplateQ::template, tem]; False)
validateTemplate[LTemplate[name_String, classes_List]] :=
    Block[{classlist = {}, location = "template"},
      validateName[name] && (And @@ validateClass /@ classes)
    ]

(* must be called within validateTemplate, uses location, classlist *)
validateClass[class_] := (Message[ValidTemplateQ::class, location, class]; False)
validateClass[LClass[name_, funs_List]] :=
    Block[{funlist = {}, inclass, nameValid},
      nameValid = validateName[name];
      If[MemberQ[classlist, name], Message[ValidTemplateQ::dupclass, location, name]; Return[False]];
      AppendTo[classlist, name];
      inclass = name;
      Block[{location = StringTemplate["class ``"][inclass]},
        nameValid && (And @@ validateFun /@ funs)
      ]
    ]

(* must be called within validateClass, uses location, funlist *)
validateFun[fun_] := (Message[ValidTemplateQ::fun, location, fun]; False)
validateFun[LFun[name_, args_List, ret_]] :=
    Block[{nameValid},
      nameValid = validateName[name];
      If[MemberQ[funlist, name], Message[ValidTemplateQ::dupfun, location, name]; Return[False]];
      AppendTo[funlist, name];
      Block[{location = StringTemplate["class ``, function ``"][inclass, name]},
        nameValid && (And @@ validateType /@ args) && validateReturnType[ret]
      ]
    ]

(* must be called within validateTemplate, uses location *)
validateType[Integer|Real|Complex|"Boolean"|"UTF8String"] := True
validateType[{Integer|Real|Complex, (_Integer?Positive) | Verbatim[_], PatternSequence[]|"Shared"|"Manual"|"Constant"|Automatic}] := True
validateType[type_] := (Message[ValidTemplateQ::type, location, type]; False)

validateReturnType["Void"] := True
validateReturnType[type_] := validateType[type]

(* must be called within validateTemplate, uses location *)
validateName[name_] := Message[ValidTemplateQ::string, location, name]
validateName[name_String] :=
    If[StringMatchQ[name, RegularExpression["[a-zA-Z][a-zA-Z0-9]*"]],
      True,
      Message[ValidTemplateQ::name, location, name]; False
    ]



(***********  Translate template to library code  **********)

TranslateTemplate[tem_] :=
    With[{t = normalizeTemplate[tem]},
      If[validateTemplate[t],
        ToCCodeString[transTemplate[t], "Indent" -> 1],
        $Failed
      ]
    ]


libFunArgs = {{"WolframLibraryData", "libData"}, {"mint", "Argc"}, {"MArgument *", "Args"}, {"MArgument", "Res"}};

excType = "const mma::LibraryError &";
excName = "libErr";


varPrefix = "var";
var[k_] := varPrefix <> IntegerString[k]


includeName[classname_String] := classname <> ".h"

collectionName[classname_String] := classname <> "_collection"

managerName[classname_String] := classname <> "_manager"

setupCollection[classname_String] := {
  StringTemplate["std::map<mint, `` *> ``"][classname, collectionName[classname]],
  "",
  CFunction["DLLEXPORT void", managerName[classname], {"WolframLibraryData libData", "mbool mode", "mint id"},
CInlineCode@StringTemplate[
"\
if (mode == 0) { // create
  // TODO check id doesn't exist
  `collection`[id] = new `class`();
} else {  // destroy
  if (`collection`.find(id) == `collection`.end()) {
    libData->Message(\"noinst\");
    return;
  }
  delete `collection`[id];
  `collection`.erase(id);
}\
"][<|"collection" -> collectionName[classname], "class" -> classname|>]
  ],
  ""
}

registerClassManager[classname_String] :=
    CBlock[{
      "int err",
      StringTemplate[
        "err = (*libData->registerLibraryExpressionManager)(\"`class`\", `manager`)"
      ][<|"class" -> classname, "manager" -> managerName[classname]|>],
      "if (err != LIBRARY_NO_ERROR) return err"
    }]


unregisterClassManager[classname_String] :=
    StringTemplate["(*libData->unregisterLibraryExpressionManager)(\"``\")"][classname]


transTemplate[LTemplate[libname_String, classes_]] :=
  Block[{classlist = {}, classTranslations},
    classTranslations = transClass /@ classes;
    {
      "",
      CInclude["LTemplate.h"],
      CInclude /@ includeName /@ classlist,
      "","",

      CInlineCode@"namespace mma { WolframLibraryData libData; }",
      "","",

      setupCollection /@ classlist,

      CFunction["extern \"C\" DLLEXPORT mint",
        "WolframLibrary_getVersion", {},
        "return WolframLibraryVersion"
      ],
      "",
      CFunction["extern \"C\" DLLEXPORT int",
        "WolframLibrary_initialize", {"WolframLibraryData libData"},
        {
          CAssign["mma::libData", "libData"],
          registerClassManager /@ classlist,
          "return LIBRARY_NO_ERROR"
        }
      ],
      "",
      CFunction["extern \"C\" DLLEXPORT void",
        "WolframLibrary_uninitialize", {"WolframLibraryData libData"},
        {
          unregisterClassManager /@ classlist,
          "return"
        }
      ],
      "",
      classTranslations
    }
  ]


(* must be called within transTemplate *)
transClass[LClass[classname_String, funs_]] :=
  Block[{},
    AppendTo[classlist, classname];
    transFun[classname] /@ funs
  ]


funName[classname_][name_] := classname <> "_" <> name

transFun[classname_][LFun[name_String, args_List, ret_]] :=
  Block[{index = 0},
    {
      CFunction["extern \"C\" DLLEXPORT int", funName[classname][name], libFunArgs,
        {
          (* TODO: check Argc is correct *)
          "const mint id = MArgument_getInteger(Args[0])",
          CInlineCode@StringTemplate[
            "if (`1`.find(id) == `1`.end()) { libData->Message(\"noinst\"); return LIBRARY_FUNCTION_ERROR; }"
          ][collectionName[classname]],
          "",
          CTryCatch[
            {
              transArg /@ args,
              "",
              transRet[
                ret,
                CPointerMember[CArray[collectionName[classname], "id"], CCall[name, var /@ Range@Length[args]]]
              ]
            },
            {excType, excName},
            {
              CCall["mma::message", {CMember[excName, "message"], "mma::ERROR"}],
              CReturn[CMember[excName, "errcode"]]
            }
          ],
          "",
          CReturn["LIBRARY_NO_ERROR"]
        }
      ],
      "", ""
    }
  ]

transArg[type_] :=
    Module[{name, cpptype, getfun, setfun},
      index++;
      name = var[index];
      {cpptype, getfun, setfun} = type /. types;
      {
        CDeclareAssign[cpptype, name, StringTemplate["`1`(Args[`2`])"][getfun, index]]
      }
    ]

transRet[type_, value_] :=
    Module[{name = "res", cpptype, getfun, setfun},
      {cpptype, getfun, setfun} = type /. types;
      {
        CDeclareAssign[cpptype, name, value],
        CCall[setfun, {"Res", name}]
      }
    ]

transRet["Void", value_] := value

types = Dispatch@{
  Integer -> {"mint", "MArgument_getInteger", "MArgument_setInteger"},
  Real -> {"double", "MArgument_getReal", "MArgument_setReal"},
  Complex -> {"std::complex<double>", "mma::getComplex", "mma::setComplex"},
  "Boolean" -> {"bool", "MArgument_getBoolean", "MArgument_setBoolean"},
  "UTF8String" -> {"char *", "MArgument_getUTF8String", "MArgument_setUTF8String"},
  {Integer, __} -> {"mma::IntTensorRef", "mma::getTensor", "mma:setTensor"},
  {Real, __} -> {"mma::RealTensorRef", "mma::getTensor", "mma::setTensor"},
  {Complex, __} -> {"mma::ComplexTensorRef", "mma::getTensor", "mma::setTensor"}
};



(**************** Load library ***************)

(* TODO: Break out loading and compilation for easy distribution *)

symName[classname_String] := "LTemplate`Classes`" <> classname

loadTemplate[tem : LTemplate[libname_String, classes_]] := (
    Quiet@unloadTemplate[tem];
    loadClass[libname] /@ classes;
  )

loadClass[libname_][tem : LClass[classname_String, funs_]] := (
    ClearAll[#]& @ symName[classname];
    With[{sym = Symbol@symName[classname]}, MessageName[sym, "usage"] = formatTemplate[tem]];
    loadFun[libname, classname] /@ funs
  )

loadFun[libname_, classname_][LFun[name_String, args_List, ret_]] :=
  With[{classsym = Symbol@symName[classname]},
    With[{lfun = LibraryFunctionLoad[libname, funName[classname][name], Prepend[args, Integer], ret]},
      classsym[id_Integer]@name[arguments___] := lfun[id, arguments]
    ]
  ]

LoadTemplate[tem_] :=
    With[{t = normalizeTemplate[tem]},
      If[validateTemplate[t],
        loadTemplate[t],
        $Failed
      ]
    ]


unloadTemplate[LTemplate[libname_String, classes_]] :=
  Module[{res},
    res = LibraryUnload[libname];
    ClearAll /@ symName /@ Cases[classes, LClass[name_, __] :> name];
    res
  ]

UnloadTemplate[tem_] :=
    With[{t = normalizeTemplate[tem]},
      If[validateTemplate[t],
        unloadTemplate[t],
        $Failed
      ]
    ]


Make[class_Symbol] := Make@SymbolName[class]
Make[classname_String] := CreateManagedLibraryExpression[classname, Symbol@symName[classname]]



(********************* Compile template ********************)

(* TODO: Allow for specifying additional implementation files. *)

CompileTemplate[tem_, opt : OptionsPattern[CreateLibrary]] :=
  With[{t = normalizeTemplate[tem]},
    If[validateTemplate[t],
      compileTemplate[t, opt],
      $Failed
    ]
  ]


compileTemplate[tem: LTemplate[libname_String, classes_], opt : OptionsPattern[CreateLibrary]] :=
  Catch[
    Module[{sourcefile, code, includeDirs, classlist, print},
      print[args__] := Apply[Print, Style[#, Darker@Blue]& /@ {args}];

      print["Current directory is: ", Directory[]];
      classlist = Cases[classes, LClass[s_String, __] :> s];
      sourcefile = "LTemplate-" <> libname <> ".cpp";
      If[Not@FileExistsQ[#],
        print["File ", #, " does not exist.  Aborting."]; Throw[$Failed, compileTemplate]
      ]& /@ (# <> ".h"&) /@ classlist;
      print["Unloading library ", libname, " ..."];
      Quiet@LibraryUnload[libname];
      print["Generating library code ..."];
      code = TranslateTemplate[tem];
      If[FileExistsQ[sourcefile], print[sourcefile, " already exists and will be overwritten."]];
      Export[sourcefile, code, "String"];
      print["Compiling library code ..."];
      includeDirs = Append[OptionValue["IncludeDirectories"], $includeDirectory];
      CreateLibrary[{sourcefile}, libname, "IncludeDirectories" -> includeDirs, Sequence@@FilterRules[{opt}, Except["IncludeDirectories"]]]
    ],
    compileTemplate
  ]


(****************** Pretty print a template ********************)

FormatTemplate[template_] :=
    Block[{LFun, LClass, LTemplate},
    (* If the template is invalid, we report errors but we do not abort.
       Pretty-printing is still useful for invalid templates to facilitate finding mistakes.
     *)
      ValidTemplateQ[template];
      formatTemplate@normalizeTemplate[template]
    ]


formatTemplate[template_] :=
  Block[{LFun, LClass, LTemplate},
    With[{tem = template /. normalizeTypesRules},
      LFun[name_, args_, ret_] := StringTemplate["`` ``(``)"][ret, name, StringJoin@Riffle[ToString /@ args, ", "]];
      LClass[name_, funs_] := StringTemplate["class ``:\n``"][name, StringJoin@Riffle["    " <> ToString[#] & /@ funs, "\n"]];
      LTemplate[name_, classes_] := StringTemplate["template ``\n\n"][name] <> Riffle[ToString /@ classes, "\n\n"];
      tem
    ]
  ]


End[] (* End Private Context *)

EndPackage[]

If[Not@MemberQ[$ContextPath, "LTemplate`Classes`"],  PrependTo[$ContextPath, "LTemplate`Classes`"]];