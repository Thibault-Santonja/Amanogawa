// import
import {Button, Form, FormGroup, Input, Label} from "reactstrap";
import {useState} from "react";


// Component
function Edit() {
    const [event, setEvent] = useState({
        'name': null,
        'dateBegin': null,
        'dateEnd': null,
        'wikiAPILink': null,
        'location': null
    })

    /*
    const [name, setName] = useState('')
    const [dateBegin, setDateBegin] = useState('')
    const [dateEnd, setDateEnd] = useState('')
    const [wikiAPILink, setWikiAPILink] = useState('')
    const [location, setLocation] = useState('')
    */

    function handleChange(e) {
        let update = event;
        update[e.target.id] = e.target.value;

        setEvent(update);
    }

    function handleSubmit() {
        console.log(event);
    }

    return (
        <div>
            <br/>
            <h1>Todo</h1>
            <Form>
                <FormGroup>
                    <Label for="name">Name</Label>
                    <Input type="textarea" name="textarea" id="name" placeholder="Name" onChange={e => handleChange(e)} />
                </FormGroup>
                <FormGroup>
                    <Label for="dateBegin">Date begin</Label>
                    <Input type="date" name="date" id="dateBegin" placeholder="Date begin" onChange={e => handleChange(e)} />
                </FormGroup>
                <FormGroup>
                    <Label for="dateEnd">Date end</Label>
                    <Input type="date" name="date" id="dateEnd" placeholder="Date end" onChange={e => handleChange(e)} />
                </FormGroup>
                <FormGroup>
                    <Label for="wikiAPILink">Wikipedia API Link</Label>
                    <Input type="url" name="url" id="wikiAPILink" placeholder="Wikipedia API Link" onChange={e => handleChange(e)} />
                </FormGroup>
                <Button onClick={handleSubmit} >Submit</Button>
            </Form>
        </div>
    )
}

export default Edit;