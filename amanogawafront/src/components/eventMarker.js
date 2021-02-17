import React, {useEffect, useState} from "react";
import {getGeopointData} from "../utils/geoTools";
import axios from "axios";
import {Marker, Popup} from "react-leaflet";
import {convertDatabase2Date} from "../utils/dateTools";
import withListLoading from "./withListLoading";

export default function EventMarker(props) {
    let event = props.event;
    //const [showDetails, setShowDetails] = useState(false);
    /*const [appState, setAppState] = useState({
        loading: false
    });*/

    const [eventData, setEventData] = useState({
        begin: event.begin,
        end: event.end,
        geolocation: getGeopointData(event.geolocation),
        name: event.name,
        description: event.description,
        descriptionFull: event.extract,
        wiki_link: event.wiki_link
    });
    console.log(eventData)
    // Effect
    /*useEffect(() => {

        // fixme : React Hook useEffect has a missing dependency: 'fetchData'. Either include it or remove the
        //  dependency array  react-hooks/exhaustive-deps
        //  eslint-disable-next-line
    }, []);*/

    //setAppState.loading = true;

    //fetchData();

    // Data
    /*function fetchData() {
        axios
            .get(eventData.wiki_linkAPI)
            .then((res) => {
                console.log(res.data);
                setEventData.descriptionFull = res.data.extract
                setEventData.wiki_link = res.data.content_urls.desktop.page
                setAppState.loading = false;
            })
            .catch(error => {
                //console.error(error);
            });
    }*/


    // Render
    return (
        <Marker position={[eventData.geolocation.latitude, eventData.geolocation.longitude]}>
            <Popup>
                {/*appState.loading*/ false ? (
                    <withListLoading />
                ) : (
                    <>
                        <h3>{eventData.name}</h3>
                        <p>{convertDatabase2Date(eventData.begin)} - {convertDatabase2Date(eventData.end)}</p>
                        <p>{eventData.description}</p>
                        {/*eventData.wiki_linkAPI ? (
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
                        ) : (<p></p>)*/}
                        <h4>{"Extract"}</h4>
                        <p>{eventData.extract}</p>
                        <a href={eventData.wiki_link}>Wiki link</a>
                    </>
                )}
            </Popup>
        </Marker>
    );

}