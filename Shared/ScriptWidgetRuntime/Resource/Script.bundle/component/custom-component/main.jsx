
//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Custom Component
// Thanks for Reina for telling me this good idea
// 


// Custom component is a JavaScript function
// with one parameter composed with : prop1,prop2... and children
// As a convention, 
// the first letter of custom component's name must be uppercase.
// For example : LeftAlign , MyCustomComponent ... etc...


// prototype:
// 1. new style
// const MyComponent = ({prop1, prop2, children}) => { /* ... */ }
// 
// 2. old style
// const MyComponent = (props) => { 
//   let prop1 = props.prop1;
//   let prop2 = props.prop2;
//   let children = props.children;
// }

const LeftAlign = ({ message, children }) => {
    return (
        <hstack>
            {children}
            <text> ({message}) </text>
            <spacer />
        </hstack>
    )
}
const RightAlign = ({ message, children }) => {
    return (
        <hstack>
            <spacer />
            <text> ({message}) </text>
            {children}
        </hstack>
    )
}
$render(
    <vstack
        background="blue"
        frame="max,center"
    >
        <LeftAlign message="L">
            <text> this text left aligned</text>
        </LeftAlign>
        <RightAlign message="R">
            <text> text right aligned</text>
        </RightAlign>
    </vstack>
);

