// import
import {Button, Form, FormGroup, Input, Label} from "reactstrap";
import {useState} from "react";


// Component
function Edit() {
    const [event, setEvent] = useState({
        'name'          : null,
        'dateBegin'     : null,
        'dateEnd'       : null,
        'wikiAPILink'   : null,
        'location'      : null
    });

    function handleChange(data) {
        console.log(data);
    }

    return (
        <div>
            <br/>
            <h1>Todo</h1>
            <Form>
                <FormGroup>
                    <Label for="name">Name</Label>
                    <Input type="textarea" name="textarea" id="name" placeholder="Name" />
                </FormGroup>
                <FormGroup>
                    <Label for="dateBegin">Date begin</Label>
                    <Input type="date" name="date" id="dateBegin" placeholder="Date begin" />
                </FormGroup>
                <FormGroup>
                    <Label for="dateEnd">Date end</Label>
                    <Input type="date" name="date" id="dateEnd" placeholder="Date end" />
                </FormGroup>
                <FormGroup>
                    <Label for="wikiAPILink">Wikipedia API Link</Label>
                    <Input type="url" name="url" id="wikiAPILink" placeholder="Wikipedia API Link" />
                </FormGroup>
                <Button onClick={handleChange} >Submit</Button>
            </Form>
        </div>
    )
}

export default Edit;