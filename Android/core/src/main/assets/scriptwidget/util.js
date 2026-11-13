
class ScriptWidget {
    static createElement(tag, props, ...children) {
//        console.log(tag);
//        console.log(props);
//
//        for (let child of children) {
//            console.log(child);
//        }
        
        return $element.createElement(tag, props, children);
    }
    
    /*
     short syntax for
     <>
         <text>1</text>
         <text>1</text>
     </>
     
     */
    static Fragment = "Fragment"
}

function $gradient(obj) {
    return "gradient:" + JSON.stringify(obj)
}

function $animation(obj) {
    return "animation:" + JSON.stringify(obj)
}

function $json(obj) {
    return JSON.stringify(obj)
}

const $xml = Object.freeze({
    parse(source) {
        if (typeof source !== "string") {
            throw new TypeError("$xml.parse expects a string")
        }
        const result = JSON.parse($xml_parse(source))
        if (!result.ok) {
            throw new Error(result.error)
        }
        return result.value
    }
})

function $type_of_object(obj) {
    return typeof obj
}
