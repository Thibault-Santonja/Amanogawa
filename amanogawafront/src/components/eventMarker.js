import React, {useState} from "react";
import {Marker, Popup} from "react-leaflet";
import {Button} from "reactstrap";
import {getGeopointData} from "../utils/geoTools";
import {convertDatabase2Date} from "../utils/dateTools";

export default function EventMarker(props) {
    let event = props.event;
    const [showDetails, setShowDetails] = useState(false);

    const eventData = {
        begin: event.begin,
        end: event.end,
        geolocation: getGeopointData(event.geolocation),
        name: event.name,
        description: event.description,
        descriptionFull: event.extract,
        wiki_link: event.wiki_link
    };

    // Render
    return (
        <Marker position={[eventData.geolocation.latitude, eventData.geolocation.longitude]}>
            <Popup>
                <h3>{eventData.name}</h3>
                <p>{convertDatabase2Date(eventData.begin)} - {convertDatabase2Date(eventData.end)}</p>
                <p>{eventData.description}</p>
                {eventData.wiki_link ? (
                    <Button outline color="info" block onClick={setShowDetails(!showDetails)}>More details</Button>
                ) : (
                    <Button outline color="info" block disabled>More details (link missed...)</Button>
                )}
                {showDetails ? (
                    <>
                        <h4>{"Extract"}</h4>
                        <p>{eventData.extract}</p>
                        <a href={eventData.wiki_link}>Wiki link</a>
                    </>
                ) : (<p></p>)}
            </Popup>
        </Marker>
    );

}