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


function setMarks() {
    let label;
    let marks = [
        {
            value: endTime,
            label: 'Today',
        },
    ];

    for (let i = startTime/1000; i < Math.floor(endTime/1000); i++) {
        if (i !== 0)
            label = (i*1000).toString()
        else
            label = 'JC'

        marks.push({
            value: i*1000,
            label: label
        })
    }

    return marks;
}


export default function TimelineSlider(props) {
    const marks = setMarks()
    const [dateRange, setDateRange] = useState([0, endTime]);
    const handleChange = (event, newValue) => {
        setDateRange(newValue);
    };

    return (<Slider
        value={dateRange}
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
                        <h2>Test timeline :</h2>
                        <p>Timeline Range Slider : {startTime} to {endTime}</p>
                        <TimelineSlider startTime={startTime} endTime={endTime}/>
                    </div>
                </div>
            </>
        )
    };
}

export {Index};