import React, {useState,useEffect} from 'react';
import axios from "axios";
import {ListGroup, ListGroupItem, Row, Col, Container, Table} from "reactstrap";

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
            const {begin, end, location, name, description, link, type} = entry;
            return (
                <tr key={index}>
                    <td>{name}</td>
                    <td>{begin}</td>
                    <td>{end}</td>
                    <td>{location}</td>
                    <td>{description}</td>
                    <td>{link}</td>
                    <td>{type}</td>
                </tr>
            )
            })
    }

    return (
        <>
            <Container>
                <Row>
                <h1>Events :</h1>
                    <ListGroup>
                        {event.map((a)=>{
                            return (
                                <ListGroupItem><p>
                                    {a.name}
                                </p></ListGroupItem>
                            )
                        })}
                    </ListGroup>
                </Row>
            </Container>
        </>
    )
};

const Event = (props) => {
    //Hooks
    const [event, setEvent] = useState([]);

    //Effect
    useEffect(() => {
        fetchData();
    }, []);

    //Data
    function fetchData(){
        console.log("fetchData");
        axios
            .get('/events/')
            .then((res)=>{
                console.log(res.data);
                setEvent(res.data);
            })
            .catch(error => {
                console.error(error);
            });
    }

    //Logic


    //Render
    return(
        <>
            {event !== null && event.length > 0 &&
                <ShowEvent
                    event={event}
                />
            }
        </>
    )
};

export {Event};