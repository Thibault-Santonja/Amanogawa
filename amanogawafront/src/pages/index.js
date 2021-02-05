import React, {Component, useState } from 'react';
import 'bootstrap/dist/css/bootstrap.min.css';

// Timeline Range Slider
import Slider from '@material-ui/core/Slider';

// Resources
import logo from '../assets/YoDance.gif';



const startTime = -4000;
const endTime   = new Date().getFullYear();


function valuetext(value) {
    return `${value}`;
}

export default function TimelineSlider(props) {
    const marks = [
        {
            value: -4000,
            label: '-4000',
        },
        {
            value: 0,
            label: 'JC',
        },
        {
            value: 1000,
            label: '1000',
        },
        {
            value: 2000,
            label: '2000',
        },
    ];
    const [value, setValue] = useState([20, 37]);
    const handleChange = (event, newValue) => {
        setValue(newValue);
    };

    return (<Slider
        value={value}
        onChange={handleChange}
        valueLabelDisplay="auto"
        aria-labelledby="range-slider"
        getAriaValueText={valuetext}
        min={props.startTime}
        max={props.endTime}
        marks={marks}
    />);
}


class Index extends Component {
    render() {
        return(
            <>
                <h1>Welcome !</h1>
                <p>TODO</p>
                <img src={logo} alt="loading..." />
                <div className="d-flex justify-content-center fixed-bottom">
                    <div className="w-75">
                        <p>Timeline Range Slider : {startTime} to {endTime}</p>
                        <TimelineSlider startTime={startTime} endTime={endTime}/>
                    </div>
                </div>
            </>
        )
    };
}

export {Index};