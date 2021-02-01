import React, {useState,useEffect} from 'react';
import {Row, Col, Container, Table} from "reactstrap";
import axios from "axios";
import withListLoading from '../components/withListLoading';
import {getGeopointData} from '../utils/geoTools'

const ShowEvents = (props) => {
    let events = props.events;

    //Logic
    function generateHeader(){
        return (
            <tr key="listEventsHeader" style={{textAlign : "center"}}>
                <th>Name</th>
                <th>Begin</th>
                <th>End</th>
                <th>Location (lon, lat)</th>
                <th>Description</th>
                <th>Wiki link</th>
            </tr>
        );
    }

    function generateList(){
        return events.map((entry, index) => {
            const {begin, end, geolocation, name, description, wiki_link} = entry;
            let coord = getGeopointData(geolocation)

            return (
                <tr key={index}>
                    <td>{name}</td>
                    <td>{begin}</td>
                    <td>{end}</td>
                    <td>[{coord.longitude}, {coord.latitude}]</td>
                    <td>{description}</td>
                    <td>{wiki_link}</td>
                </tr>
            )
            })
    }


    //Render
    return (
        <>
            <Container>
                <Row>
                    <Col>
                        <Table className="headerFixAlign" bordered>
                            <thead>
                            {generateHeader()}
                            </thead>
                            <tbody id="listBody">
                            {generateList()}
                            </tbody>
                        </Table>
                    </Col>
                </Row>
            </Container>
        </>
    )
};

const Events = (props) => {
    //Hooks
    const [events, setEvents] = useState([]);

    //Effect
    useEffect(() => {
        fetchData();
    }, []);

    //Data
    function fetchData(){
        axios
            .get('/events/')
            .then((res)=>{
                console.log(res.data);
                setEvents(res.data);
            })
            .catch(error => {
                console.error(error);
            });
    }

    //Logic


    //Render
    return(
        <>
            <h1>Events list</h1>
            {events !== null /*&& events.length > 0*/ &&
                <ShowEvents events={events} /> }
            {events == null &&
                <withListLoading /> }
        </>
    )
};

export {Events};