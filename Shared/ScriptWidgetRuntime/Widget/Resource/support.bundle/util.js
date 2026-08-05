
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

function $type_of_object(obj) {
    return typeof obj
}
