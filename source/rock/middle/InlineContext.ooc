
import structs/[ArrayList, HashMap]
import ../frontend/Token
import ../io/TabbedWriter
import Block, VariableAccess, FunctionCall, Cast, VariableDecl, TypeDecl,
       BaseType, Visitor, Node, FunctionDecl, Type
import algo/autoReturn

import tinker/[Trail, Resolver, Response]

// FIXME: highly experimental. Don't touch under death penalty.

InlineContext: class extends Block {

    returnType : Type
    returnArgs := ArrayList<VariableDecl> new()

    fCall: FunctionCall
    ref: FunctionDecl
    casted := HashMap<VariableDecl, VariableDecl> new()

    thisDecl = null, realThisDecl = null : VariableDecl

    label: String

    init: func (=fCall, .token) {
        super(token)

        // Store the ref on our own, just in case
        ref = fCall ref

        // figure out a label
        label = generateTempName("blackhole")

        if(fCall expr) {
            // We use a fake 'this' to intercept variable access resolution
            // and substitute generic types with real types
            thisTypeName := fCall expr getType() getName()
            thisType := BaseType new(thisTypeName, fCall expr token)
            thisTypeDecl := InlinedType new(this, thisTypeName)
            thisType setRef(thisTypeDecl)

            thisDecl = VariableDecl new(thisType, "this", fCall expr, fCall expr token)
            realThisDecl = VariableDecl new(null, "this", fCall expr, fCall expr token)
        }

        "== Inline context of %s's ref has %d, and fCall has %d! ==" printfln(toString(), fCall ref getReturnArgs() size(), fCall getReturnArgs() size())
        returnType = ref returnType realTypize(fCall)
        "Return type of ref is %s, ours is %s" printfln(ref returnType toString(), returnType toString())

    }

    accept: func (v: Visitor) {
        // here we play a little trick on our backend:
        // the real this decl has to be written if we're a member call,
        // because, you know, otherwise this can't be accessed.
        // but since we have been using a fake 'this' to intercept
        // variable access resolution, we weren't able to simply add
        // it to the body during the resolution phase (the real 'this'
        // would've been used for resolution, ruining our evil plan)
        // Hence, we add it here, just for the backend to see.

        hasThis? := (fCall expr != null &&
                     fCall expr instanceOf?(VariableAccess) &&
                     fCall expr as VariableAccess getName() == "this"
                    )

        if(!hasThis? && realThisDecl != null) {
            // whoopsie-daisy
            body add(0, realThisDecl)
        }

        // as usual
        super(v)

        if(!hasThis? && realThisDecl != null) {
            // there we go. nobody noticed.
            body removeAt(0)
        }
    }

    resolve: func (trail: Trail, res: Resolver) -> Response {
        if(realThisDecl) {
            if(!realThisDecl resolve(trail, res) ok()) return Responses OK
        }

        response := super(trail, res)
        if(!response ok()) {
            return response
        }

        autoReturn(trail, res, this, body, returnType)
    }

    resolveCall: func (call: FunctionCall, res: Resolver, trail: Trail) -> Int {
        "====================================" println()
        "In inline context of %s, looking for call %s" printfln(fCall toString(), call toString())

        "fCall expr = %s" printfln(fCall expr ? fCall expr toString() : "<null>")
        if(fCall expr != null) {
            exprType := fCall expr getType()
            if(exprType != null && exprType getRef() != null) {
                ref := exprType getRef()
                "ref is %s (%p) and it's a %s" printfln(ref toString(), ref, ref class name)

                proxy := FunctionCall new(call getName(), call token)
                proxy args addAll(call args)
                proxy expr = fCall expr
                ref as TypeDecl getMeta() resolveCall(proxy, res, trail)
                if(proxy ref != null) {
                    "resolved to %s" printfln(proxy ref toString())
                    call expr = fCall expr
                    if(call suggest(proxy ref)) {
                        "Congratulations soldier" println()
                        return 0
                    } else {
                        call expr = null
                    }
                }
            }
        }

        super(call, res, trail)
    }

    resolveAccess: func (access: VariableAccess, res: Resolver, trail: Trail) -> Int {
        "====================================" println()
        "In inline context of %s, looking for access %s" printfln(fCall toString(), access toString())

        if(fCall expr != null) {
            exprType := fCall expr getType()
            if(exprType != null && exprType getRef() != null) {
                ref := exprType getRef()
                "ref is %s" printfln(ref toString())

                if(access getName() == "this") {
                    if(access suggest(thisDecl)) {
                        "We did it, honey!" println()
                        return 0
                    }
                }

                proxy := access clone() as VariableAccess
                ref resolveAccess(proxy, res, trail)
                if(proxy ref != null) {
                    "resolved to %s" printfln(proxy ref toString())
                    targetType := proxy ref getType()
                    realType := targetType realTypize(fCall)

                    suggestion : VariableDecl = null
                    adjustExpr? := false

                    if(targetType equals?(realType)) {
                        "Equal types! suggesting %s" printfln(proxy ref toString())
                        suggestion = proxy ref
                        adjustExpr? = true
                    } else {
                        "Casting! targetType = %s, realType = %s" printfln(targetType toString(), realType toString())
                        realtypized := VariableDecl new(null, proxy getName(), Cast new(proxy, realType, proxy ref token), proxy ref token)
                        realtypized owner = fCall ref owner

                        varAcc := VariableAccess new("this", nullToken)
                        varAcc ref = realThisDecl
                        proxy expr = varAcc

                        casted put(proxy ref as VariableDecl, realtypized) // TODO: use that later, in case of multiple access
                        // 1 = after this :) hackhackhack!
                        body add(1, realtypized)
                        suggestion = realtypized
                    }
                    if(suggestion != null && access suggest(suggestion)) {
                        " - Suggestion worked o/" println()
                        if(suggestion owner != null && adjustExpr?) {
                            "Ooh, owner of %s isn't null. Setting expr :D" printfln(suggestion toString())
                            thisAcc := VariableAccess new("this", token)
                            thisAcc ref = realThisDecl
                            access expr = thisAcc
                        }
                        return 0
                    }
                }
            }
        }

        super(access, res, trail)
    }

    toString: func -> String {
        ("[InlineContext of %s] " format(fCall toString())) + super()
    }

}

InlinedType: class extends TypeDecl {

    context: InlineContext

    init: func ~inlinedType (=context, .name) {
        super("<Inlined " + name + ">", null, nullToken)
    }

    clone: func -> This {
        this
    }

    underName: func -> String { name }

    accept: func (v: Visitor) { /* yeah, right. */ }

    writeSize: func (w: TabbedWriter, instance: Bool) { Exception new(This, "writeSize() called on an InlinedType. wtf?") throw() /* if this happens, we're screwed */ }

    replace: func (oldie, kiddo: Node) -> Bool { false }

    resolveAccess: func (access: VariableAccess, res: Resolver, trail: Trail) -> Int {
        "====================================" println()
        "In inlined type %s, looking for access %s" printfln(toString(), access toString())

        if(access expr instanceOf?(VariableAccess)) {
            varAcc := access expr as VariableAccess
            if(varAcc getName() == "this") {
                access expr = null // mwahahaha.
                context resolveAccess(access, res, trail)
            }
        }

        0
    }

    resolveCall: func (call: FunctionCall, res: Resolver, trail: Trail) -> Int {
        if(context fCall expr) {
            ref := context fCall expr getType() getRef()
            if(ref) {
                "in InlinedType resolveCall, ref is %s and it's a %s" printfln(ref toString(), ref class name)
                return ref resolveCall(call, res, trail)
            }
        }

        0
    }

}



