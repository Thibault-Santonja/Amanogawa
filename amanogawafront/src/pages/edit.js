// import
import {Button, Form, FormGroup, Input, Label, Container, Row, Col } from "reactstrap";
import React, {useState} from "react";
import {MapContainer, TileLayer} from "react-leaflet";


// Component
function Edit() {
    const [event, setEvent] = useState({
        'name': null,
        'dateBegin': null,
        'dateEnd': null,
        'wikiAPILink': null,
        'location': null
    })

    /*const formStyle = {
        'position': 'fixed',
        'width': '18%',
        'padding': '1em'
    }*/

    function handleChange(e) {
        let update = event;
        update[e.target.id] = e.target.value;

        setEvent(update);
    }

    function handleSubmit() {
        console.log(event);
    }

    return (
        <Container fluid>
            <Row>
                <Col md={2}>
                    <br/>
                    <h3>Set information</h3>
                    <br/>
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
                </Col>

                <Col>
                    <MapContainer center={[30, 65]} zoom={4} scrollWheelZoom={true}>
                        <link
                            rel="stylesheet"
                            href="https://unpkg.com/leaflet@1.6.0/dist/leaflet.css"
                            integrity="sha512-xwE/Az9zrjBIphAcBb3F6JVqxf46+CDLwfLMHloNu6KEQCAWi6HcDUbeOfBIptF7tcCzusKFjFw2yuvEpDL9wQ=="
                            crossOrigin=""
                        />
                        <TileLayer
                            attribution='&copy; <a href="http://osm.org/copyright">OpenStreetMap</a> contributors'
                            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                        />
                    </MapContainer>
                </Col>
            </Row>
        </Container>
    )
}

export default Edit;