import React, {useState} from 'react';

// Timeline Range Slider
import Slider from '@material-ui/core/Slider';


function valuetext(value) {
    return `${value}`;
}

function setMarks(timelineRange) {
    const step = Math.round((timelineRange.end - timelineRange.start)/timelineRange.stepNumber);
    let label;
    let marks = [
        {
            value: timelineRange.end,
            label: 'Today',
        },
        {
            value: 0,
            label: 'JC',
        },
    ];

    for (let i = timelineRange.start / step; i < Math.floor(timelineRange.end / step); i++) {
        if (i !== 0) {
            label = (i * step).toString()
            marks.push({
                value: i * step,
                label: label
            })
        }
    }

    return marks;
}


// source : https://material-ui.com/components/slider/
export default function TimelineSlider(props) {
    const timelineRange = {start:props.startTime, end:props.endTime, stepNumber:props.stepNumber};
    const marks = setMarks(timelineRange)
    const [dateRange, setDateRange] = useState([0, timelineRange.end]);
    //let timeout = setTimeout(() => {console.log(dateRange)}, 3000);

    const handleChange = (event, newValue) => {
        setDateRange(newValue);
        props.handleChange(newValue);
    };
    /*
    const callback = () => {
        axios.get('/events/', {params: {start: dateRange[0], end: dateRange[1]}})
             .then((res)=>{
                 console.log(res.data);
             })
    };
    */

    return (<Slider
        value={dateRange}
        onChange={handleChange}
        valueLabelDisplay="auto"
        aria-labelledby="range-slider"
        getAriaValueText={valuetext}
        min={timelineRange.start}
        max={timelineRange.end}
        marks={marks}
    />);
}