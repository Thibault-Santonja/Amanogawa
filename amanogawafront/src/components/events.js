import React from 'react';
import {Row, Col, Container, Table} from "reactstrap";

const ShowEvent = (props) => {
    let event = props.event;

    function generateHeader(){
        return (
            <tr key="listEventHeader" style={{textAlign : "center"}}>
                <th>Name</th>
                <th>Begin</th>
                <th>End</th>
                <th>Location</th>
                <th>Description</th>
                <th>Wiki link</th>
            </tr>
        );
    }

    function generateList(){
        return event.map((entry, index) => {
            const {begin, end, location, name, description, link} = entry;
            return (
                <tr key={index}>
                    <td>{name}</td>
                    <td>{begin}</td>
                    <td>{end}</td>
                    <td>{location}</td>
                    <td>{description}</td>
                    <td>{link}</td>
                </tr>
            )
        })
    }

    return (
        <>
            <Container>
                <Row>
                    <Col>
                        <Table className="headerFixAlign" bordered>
                            <thead>
                            {generateHeader()}
                            </thead>
                            {
                                props.event !== null ? (
                                <tbody id="listBody"> {generateList()} </tbody>) : (<></>)
                            }
                        </Table>
                    </Col>
                </Row>
            </Container>
        </>
    )
};

export default ShowEvent;