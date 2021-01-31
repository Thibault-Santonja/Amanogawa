import React, {useState,useEffect} from 'react';
import Axios from 'axios'
import {ListGroup, ListGroupItem} from "reactstrap";

const ShowEvent = (props) => {
    let event = props.event;

    return (
        <>
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
        </>
    )
};

const Event = (props) => {
    //Hooks
    const [event, setEvent] = useState(null);

    //Effect
    useEffect(() => {
        fetchData();
    }, []);

    //Data
    function fetchData(){
        console.log("fetchData");
        Axios.get('http://localhost:8000/events/1/')
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
            <h1>Event</h1>
            {event !== null &&
                <ShowEvent
                    event={event}
                />
            }
            <h1>End Event</h1>
        </>
    )
};

export {Event};